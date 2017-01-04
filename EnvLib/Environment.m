/*
 * Copyright 2012, 2017 Hannes Schmidt
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Environment.h"
#import "Error.h"
#import "NSFileManager+EnvLib.h"
#import "NSDictionary+EnvLib.h"

#include "Constants.h"

#include "launchd_xpc.h"
#include "launchd_legacy.h"

@implementation Environment

static NSString* savedEnvironmentPath;

+ (void) initialize
{
    savedEnvironmentPath = [@"~/.MacOSX/environment.plist" stringByExpandingTildeInPath];
}

+ (NSString*) savedEnvironmentPath
{
    return savedEnvironmentPath;
}

/**
 * Designated initializer
 */
- initWithDictionary: (NSDictionary*) dict {
    if( self = [super init] ) {
        _dict = dict;
    }
    return self;
}

+ (Environment*) loadPlist
{
    NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile: savedEnvironmentPath];
    Environment* env = [self alloc];
    return [env initWithDictionary: dict == nil ? @{}: dict];
}

- (BOOL) savePlist: (NSError**) error
{
    return [_dict writeToFile: savedEnvironmentPath
                   atomically: YES
                 createParent: YES
              createAncestors: NO
                        error: error];
}

- (NSMutableArray*) toArrayOfEntries
{
    NSMutableArray *array = [NSMutableArray arrayWithCapacity: _dict.count];
    [_dict enumerateKeysAndObjectsUsingBlock: ^ ( NSString *key, NSString *value, BOOL *stop ) {
         if( value != nil ) [array addObject: @{ @"name": key, @"value": value }.mutableCopy];
     }];
    return array;
}

+ (Environment*) withArrayOfEntries: (NSArray*) array
{
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionaryWithCapacity: [array count]];
    [array enumerateObjectsUsingBlock: ^ ( NSDictionary *entry, NSUInteger idx, BOOL *stop ) {
         NSString *key = [entry valueForKey: @"name"];
         NSString *value = [entry valueForKey: @"value"];
         if( key != nil && value != nil ) [mutDict setObject: value forKey: key];
     }];
    Environment* env = [self alloc];
    NSDictionary* dict = [NSDictionary dictionaryWithDictionary: mutDict];
    return [env initWithDictionary: dict];
}


- (void)export {
    NSMutableSet *oldVariables;
    const char *pcOldVariables = getenv( agentName "_vars" );
    if( pcOldVariables == NULL ) {
        oldVariables = [NSMutableSet set];
    } else {
        NSString *oldVariablesStr = [NSString stringWithCString: pcOldVariables
                                                       encoding: NSUTF8StringEncoding];
        oldVariables = [NSMutableSet setWithArray: [oldVariablesStr componentsSeparatedByString: @" "]];
        // in case oldVariables was empty or had multiple consecutive separators:
        [oldVariables removeObject: @""];
    }
    NSSet *newVariables;
    if( kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber10_10 ) {
        newVariables = [NSMutableSet set];
        [_dict enumerateKeysAndObjectsUsingBlock: ^( NSString *key, NSString *value, BOOL *stop ) {
            if( value != nil ) {
                NSLog( @"Setting '%@' to '%@' using legacy launchd API.", key, value );
                envlib_setenv( key.UTF8String, value.UTF8String );
                [oldVariables removeObject: key];
                [(NSMutableSet *) newVariables addObject: key];
            }
        }];
        [oldVariables enumerateObjectsUsingBlock: ^( NSString *key, BOOL *stop ) {
            NSLog( @"Unsetting '%@' using legacy launchd API.", key );
            envlib_unsetenv( key.UTF8String );
        }];
    } else {
        newVariables = [_dict keysOfEntriesPassingTest: ^BOOL( NSString *key, NSString *value, BOOL *stop ) {
            return value != nil;
        }];
        [oldVariables minusSet: newVariables];
        EnvEntry env[[newVariables count] + [oldVariables count] + 1];
        EnvEntry *entry = env;
        for( NSString *name in newVariables ) {
            NSString *value = _dict[ name ];
            NSLog( @"Setting '%@' to '%@' using XPC launchd API.", name, value );
            entry->name = name.UTF8String;
            entry->value = value.UTF8String;
            entry++;
        }
        for( NSString *name in oldVariables ) {
            NSLog( @"Unsetting '%@' using XPC launchd API.", name );
            entry->name = name.UTF8String;
            entry->value = NULL;
            entry++;
        }
        // Add sentinel
        entry->name = NULL;
        entry->value = NULL;
        // XPC API allows for setting and unsetting of variables in one call
        envlib_setenv_xpc( env );
    }
    const char *pcNewVariables = [[newVariables allObjects] componentsJoinedByString: @" "].UTF8String;
    envlib_setenv( agentName "_vars", pcNewVariables );
}

- (BOOL) isEqualToEnvironment: (Environment*) other
{
    return [_dict isEqualToDictionary: other->_dict];
}

@end

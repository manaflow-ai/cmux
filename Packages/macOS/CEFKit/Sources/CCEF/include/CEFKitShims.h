#ifndef CEFKIT_SHIMS_H_
#define CEFKIT_SHIMS_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Sequentially-consistent 32-bit atomics for the CEF ref-count protocol.
// Swift cannot touch C atomics directly, so these three calls are the only C
// code in the bindings.
void cefkit_atomic_store(int32_t *ptr, int32_t value);
int32_t cefkit_atomic_add(int32_t *ptr, int32_t delta);
int32_t cefkit_atomic_load(int32_t *ptr);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <AppKit/AppKit.h>

// Mirrors include/cef_application_mac.h. libcef checks at runtime that NSApp
// conforms to these protocols (matched by name), so declaring them here lets a
// Swift NSApplication subclass satisfy the check without any ObjC++ sources.
@protocol CrAppProtocol
- (BOOL)isHandlingSendEvent;
@end

@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

@protocol CefAppProtocol <CrAppControlProtocol>
@end
#endif  // __OBJC__

#endif  // CEFKIT_SHIMS_H_

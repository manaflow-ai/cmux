#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stddef.h>

#if defined(__APPLE__)
#define GHOSTTY_RUNTIME_TEST_STUB_WEAK __attribute__((weak))
#else
#define GHOSTTY_RUNTIME_TEST_STUB_WEAK
#endif

// Test-only weak stand-ins for libghostty symbols reached by
// GhosttyRuntimeCInterop and GhosttySurfaceRuntimeProbe. Plain SwiftPM still
// cannot reliably link GhosttyKit's macOS archive because its static library is
// not lib-prefixed, while xcodebuild now links that archive for this package.
// Weak definitions let xcodebuild use GhosttyKit's real symbols and let SwiftPM
// tests link fallback symbols no test calls.
GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_new_with_scrollback_limit(
    void *app,
    const void *config,
    size_t scrollback_limit_bytes);

GHOSTTY_RUNTIME_TEST_STUB_WEAK bool ghostty_surface_clear_selection(void *surface);

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_quicklook_font(void *surface);

#endif

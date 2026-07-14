#ifndef GHOSTTY_RUNTIME_TEST_STUBS_H
#define GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stdint.h>

// Test-only stand-in for the libghostty symbol bound by @_silgen_name in
// GhosttyRuntimeCInterop. SwiftPM cannot link the GhosttyKit macOS archive
// (its binary is not lib-prefixed), so the test runner provides this stub to
// satisfy the link; no test calls it.
bool ghostty_surface_clear_selection(void *surface);

// Test-only stand-in for the GhosttyKit symbol referenced by
// GhosttySurfaceRuntimeProbe.currentSurfaceFontSizePoints; no test calls it.
void *ghostty_surface_quicklook_font(void *surface);

// Test-only stand-in for the GhosttyKit symbol referenced by
// GhosttyRuntimeCInterop.createSurface; no package test calls it.
void *ghostty_surface_new_with_scrollback_limit(
    void *app,
    const void *config,
    uintptr_t scrollback_limit_bytes
);

#endif

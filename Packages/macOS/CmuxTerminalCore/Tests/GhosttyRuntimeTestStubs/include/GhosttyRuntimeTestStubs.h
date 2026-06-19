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

// Test-only stand-in for the libghostty symbol referenced by the
// GhosttyConfig runtime-read helpers (colorValue/defaultBackgroundValues/etc.);
// no test calls it. Matches GhosttyKit's
// `bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t)`.
bool ghostty_config_get(void *config, void *out, const char *key, uintptr_t len);

#endif

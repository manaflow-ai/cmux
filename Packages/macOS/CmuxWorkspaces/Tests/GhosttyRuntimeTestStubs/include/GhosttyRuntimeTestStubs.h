#ifndef CMUXWORKSPACES_GHOSTTY_RUNTIME_TEST_STUBS_H
#define CMUXWORKSPACES_GHOSTTY_RUNTIME_TEST_STUBS_H

#include <stdbool.h>
#include <stdint.h>

// Test-only stand-ins for the libghostty symbols bound by @_silgen_name inside
// CmuxTerminalCore (GhosttyRuntimeCInterop / GhosttySurfaceRuntimeProbe /
// GhosttyConfig runtime reads). CmuxWorkspaces now depends on CmuxTerminalCore
// (SurfaceCreationCoordinator promotes a CmuxSurfaceConfigTemplate), so the
// CmuxWorkspaces test runner inherits those undefined symbols at link time.
// SwiftPM cannot link the GhosttyKit macOS archive (its binary is not
// lib-prefixed), so this stub satisfies the link; no test calls these. The app
// build links the real GhosttyKit. Mirrors CmuxTerminalCore's identical stub.
bool ghostty_surface_clear_selection(void *surface);
void *ghostty_surface_quicklook_font(void *surface);
bool ghostty_config_get(void *config, void *out, const char *key, uintptr_t len);
void ghostty_set_window_background_blur(void *app, void *window);

#endif

// The DevTools frontend's own dock-side setting for a host dock side (no CEF
// needed, so tests/devtools_dock_state_test.cpp compiles it alone).
#pragma once

#include <string>

namespace cmux_shim {

// The frontend's setting name in the profile's devtools.preferences dictionary.
inline constexpr const char* kDevToolsDockStateKey = "currentDockState";

// The setting's stored value (a JSON string, as the frontend stores every
// setting) for a fork dock side: 0 undocked, 1 left, 2 bottom, 3 right (the
// values of the fork's DevTools dock-side report). Empty for any other side.
inline std::string DevToolsDockStateValue(int side) {
  switch (side) {
    case 0: return "\"undocked\"";
    case 1: return "\"left\"";
    case 2: return "\"bottom\"";
    case 3: return "\"right\"";
    default: return "";
  }
}

}  // namespace cmux_shim

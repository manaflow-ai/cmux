// Which live DevTools frontend a shim DevTools call names (no CEF needed, so
// tests/devtools_call_target_test.cpp compiles it alone).
//
// A DevTools frontend is a browser of its own (DevToolsClient), kept by the
// page it inspects, not in the page browsers' map: a call naming a frontend's
// id (cmux's window image takes the docked DevTools' Page.captureScreenshot)
// finds it here.
#pragma once

namespace cmux_shim {

// The frontend in `open` (inspected page id -> its DevTools browser) whose own
// identifier is `id`; an empty `Browser` when no open frontend has it.
template <class Browser, class Map>
Browser DevToolsFrontendIn(const Map& open, int id) {
  for (const auto& entry : open) {
    if (entry.second && entry.second->GetIdentifier() == id) return entry.second;
  }
  return Browser();
}

}  // namespace cmux_shim

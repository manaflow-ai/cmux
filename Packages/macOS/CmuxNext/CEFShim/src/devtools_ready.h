// The DevTools frontend's "loaded" signal (no CEF needed, so
// tests/devtools_ready_test.cpp compiles it alone).
//
// Chrome's DevToolsWindow shows DevTools only after its frontend called the
// embedder's loadCompleted (DevToolsUIBindings), which the frontend sends once
// its settings, theme and first UI are in place. Before that, the frontend's
// document paints unthemed (white): BROWSER VIDEO F1b saw it for 1-5 frames
// in a dark theme. The shim keeps a docked or panel DevTools window invisible
// over the pane's themed ground until the same moment: the script below runs
// in the frontend when its main frame has loaded, relays loadCompleted (or the
// app UI already up) as one console marker after the frontend's next frame,
// and DevToolsClient::OnConsoleMessage reveals the window on that marker.
#pragma once

#include <string>

namespace cmux_shim {

// The console message the frontend logs when it is ready to be shown.
inline constexpr const char* kDevToolsReadyMarker = "__cmux_devtools_frontend_ready__";

// A frontend that never reports (a future frontend without loadCompleted)
// still shows this long after its load ended.
inline constexpr int kDevToolsRevealBackstopMs = 1500;

inline bool IsDevToolsReadyMessage(const std::string& message) {
  return message == kDevToolsReadyMarker;
}

// Runs in the DevTools frontend after its main frame loaded. DevToolsAPI is
// the frontend's embedder bridge (devtools_compatibility.js; the shim already
// calls its showPanel). A frontend whose app UI is already up (loadCompleted
// sent before this ran) reports at once.
inline std::string DevToolsReadyScript() {
  std::string marker = kDevToolsReadyMarker;
  return "(function(){"
         "if(window.__cmuxReadyHooked)return;window.__cmuxReadyHooked=true;"
         "var sent=false;"
         "function ready(){if(sent)return;sent=true;"
         "requestAnimationFrame(function(){requestAnimationFrame(function(){console.debug('" + marker + "');});});}"
         "try{var api=window.DevToolsAPI;"
         "if(api&&typeof api.sendMessageToEmbedder==='function'){"
         "var send=api.sendMessageToEmbedder;"
         "api.sendMessageToEmbedder=function(method){var r=send.apply(this,arguments);"
         "if(method==='loadCompleted')ready();return r;};}}catch(e){}"
         "if(document.querySelector('.root-view'))ready();"
         "})();";
}

}  // namespace cmux_shim

// Which browser reports a renderer process's end: the request of CMUX_SHIM_RENDER_TERMINATED
// (cmux_cef_shim.h), with no CEF (scripts/cmux-next/test-shim-renderer-end-cpp.sh compiles it alone).
//
// One renderer process can host the main frames of several browsers (same-site tabs share it), and its
// end reaches each of them: RenderProcessHostImpl::ProcessDied tells every observer in one UI task
// (content/browser/renderer_host/render_process_host_impl.cc), and CEF turns each browser's
// PrimaryMainFrameRenderProcessGone into OnRenderProcessTerminated. Chrome counts the end once per
// process (components/metrics/content/content_stability_metrics_provider.cc, RenderProcessExited), so
// the first browser of an end reports it and the others say it is shared. The shim forgets the process
// in a task after that one: Chromium can launch the same render process host again.
#pragma once

#include <cstdint>
#include <set>
#include <string>

namespace cmux_shim {

inline constexpr int kRendererEndUnknown = 0;  // no main frame, so no process to name
inline constexpr int kRendererEndFirst = 1;    // the first browser of this process's end
inline constexpr int kRendererEndShared = 2;   // another browser of an end already reported

// The render process host id of a frame identifier "<render process host id>-<frame token>"
// (frame_util::MakeFrameIdentifier), which is the renderer's --renderer-client-id; 0 when it has none.
inline int RendererClientIdOf(const std::string& identifier) {
  const size_t dash = identifier.find('-');
  if (dash == std::string::npos || dash == 0) return 0;
  int id = 0;
  for (size_t i = 0; i < dash; ++i) {
    if (identifier[i] < '0' || identifier[i] > '9' || id > 100000000) return 0;
    id = id * 10 + (identifier[i] - '0');
  }
  return id > 0 ? id : 0;
}

// RENDER_TERMINATED's b: Chromium's error code in the low 32 bits and the renderer's client id (0 when the
// shim cannot name it) in the high 32. The client id is the helper's --renderer-client-id, so the app joins
// Chromium's status of the end with the child monitor's exit of the same process, which has its pid
// (Chrome keys a renderer's exit by the same host id, ChildProcessTerminationInfo in
// RenderProcessHostImpl::ProcessDied).
inline int64_t RendererEndCode(int error_code, int client) {
  const uint64_t high = static_cast<uint64_t>(static_cast<uint32_t>(client > 0 ? client : 0)) << 32;
  return static_cast<int64_t>(high | static_cast<uint32_t>(error_code));
}

// The renderer ends reported in the UI task under way, by render process host id.
class RendererEnds {
 public:
  // How one browser reports the end of renderer `client`: kRendererEndFirst once per end, then
  // kRendererEndShared until Forget(client).
  int Report(int client) {
    if (client <= 0) return kRendererEndUnknown;
    return ended_.insert(client).second ? kRendererEndFirst : kRendererEndShared;
  }

  // The end of `client` is over: the next one is a new end.
  void Forget(int client) { ended_.erase(client); }

 private:
  std::set<int> ended_;
};

}  // namespace cmux_shim

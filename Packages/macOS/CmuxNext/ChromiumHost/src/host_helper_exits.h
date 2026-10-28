// The Chromium Host's helper processes (task p01-process-225 of
// plans/cmux-next/chrome-parity/p01-process.md): the renderers, the GPU
// process, the utility processes (network service, storage, audio) and the
// extension renderers Chromium starts are children of the host, not of cmux,
// so cmux's own CEFChildProcessMonitor sees none of them in host mode. The
// host watches its children the same way (HelperExitWatcher: kqueue
// NOTE_FORK on itself, NOTE_EXEC and NOTE_EXIT with the wait status on each
// child) and forwards each helper's end as CMUX_SHIM_HELPER_EXIT
// (HostContext::HelperExited), which cmux records in debug.crashes
// (CEFRuntime.childExited) as it records a helper of its own in process.
//
// CEF reports a renderer's end per browser (OnRenderProcessTerminated) and no
// other child's. Chrome's browser process hears every child's end with its
// termination status (BrowserChildProcessHostImpl::OnChildDisconnected ->
// BrowserChildProcessObserver::BrowserChildProcessCrashed and Killed,
// content/browser/browser_child_process_host_impl.cc); the kqueue watch gives
// the host the same: the pid, the process type from the helper's argv (the
// --type switch Chrome launches it with, content/public/common/content_switches.h)
// and the wait status the kernel reported before Chromium reaped it.
//
// Everything here but HelperExitWatcher is plain C++ (host_helper_exits.cc):
// scripts/cmux-next/tests/chromium-host-dispatch.test.sh runs it on Linux.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace cmux_host {

// CMUX_SHIM_HELPER_EXIT (plans/cmux-next/chromium-host-ops.json,
// optional_events; CEFShimEvent.helperExit in cmux): browser 0, request the
// pid, a the wait status, b kHelperExitExtension for an extension renderer,
// s1 the --type, s2 the --utility-sub-type.
inline constexpr int kEventHelperExit = 68;
inline constexpr int64_t kHelperExitExtension = 1;

// What a helper is, from its argv. CEFHelperIdentity.parse in cmux reads the
// same switches.
struct HelperIdentity {
  std::string type;      // --type: renderer, gpu-process, utility, ...
  std::string sub_type;  // --utility-sub-type ("" without one)
  bool extension = false;  // --extension-process
  friend bool operator==(const HelperIdentity&, const HelperIdentity&) = default;
};

// The identity a Chromium helper's argv names; nullopt for a process with no
// --type (not a helper, or not exec'd yet: it still has the host's argv).
std::optional<HelperIdentity> HelperIdentityOf(const std::vector<std::string>& argv);

// argv from a KERN_PROCARGS2 buffer: a little-endian int32 argc, the exec
// path, NUL padding, then argc NUL-terminated arguments. Empty when the
// buffer is shorter than its argc.
std::vector<std::string> ProcArgs(std::string_view buffer);

// One helper's end: what HelperExited forwards.
struct HelperExit {
  int32_t pid = 0;
  int32_t status = 0;  // the wait status: signal in the low 7 bits, exit code in bits 8-15
  HelperIdentity identity;
};

// The host's children the watcher follows, by pid, each with its identity
// once its argv names one. Bounded by the host's live children: an end
// removes its child. The watcher's queue only, so no lock.
class HelperTable {
 public:
  // A child to follow from now on, with its identity when it already exec'd.
  void Watch(int32_t pid, std::optional<HelperIdentity> identity);
  bool Watches(int32_t pid) const { return children_.count(pid) > 0; }
  // The child exec'd: its argv is a helper's now (or not).
  void Execed(int32_t pid, std::optional<HelperIdentity> identity);
  // The child ended with `status`: its helper end, nullopt for a child that
  // never became a helper or that this table does not follow.
  std::optional<HelperExit> Exited(int32_t pid, int32_t status);
  size_t size() const { return children_.size(); }

 private:
  std::unordered_map<int32_t, std::optional<HelperIdentity>> children_;
};

// Watches the host's own children off its main thread (host_helper_watch.mm,
// macOS): a kqueue on a serial user-initiated queue, as cmux's
// CEFChildProcessMonitor does in process. `report` runs on that queue for
// each helper's end; the host hands it to its main thread.
class HelperExitWatcher {
 public:
  using Report = std::function<void(const HelperExit&)>;
  explicit HelperExitWatcher(Report report);
  HelperExitWatcher(const HelperExitWatcher&) = delete;
  HelperExitWatcher& operator=(const HelperExitWatcher&) = delete;
  // Stops the watch; a report already on its way may still run.
  ~HelperExitWatcher();
  // Starts the watch and follows every child the host has now; false when
  // the kqueue cannot be made (logged), and nothing is reported.
  bool Start();

 private:
  struct State;
  std::shared_ptr<State> state_;
};

}  // namespace cmux_host

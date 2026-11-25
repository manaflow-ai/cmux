// Which quit signals a CEF helper (renderer, extension renderer, GPU, utility)
// obeys. No CEF needed, so CEFShim/tests/helper_signal_policy_test.cpp compiles
// it alone (scripts/cmux-next/test-shim-helper-signals-cpp.sh).
//
// Chromium resets SIGTERM, SIGINT and SIGHUP to their default action in every
// child (content_main.cc SetupSignalHandlers), so a quit signal that reaches
// the helpers as well as the app ends them first: Ctrl-C in the terminal that
// started the app (the whole process group), `pkill cmux` or `killall` by name
// (the helpers are "<App> Helper (Renderer)" and so on), or anything else that
// signals the app's group. The app takes the same signal as a graceful quit
// (QuitSignal) and keeps Chromium running while it saves, so Chromium sees the
// built-in uBlock Origin's background page die with no shutdown under way and
// shows its "uBlock Origin has crashed. Click this balloon to reload the
// extension." popup at the top right of the screen
// (BackgroundContentsService::HandleExtensionCrashed; Leo, 2026-11-03).
//
// So a helper obeys one of these signals only from its own browser process
// (Chromium ends helpers it no longer needs with SIGTERM, base::Process::
// Terminate), from itself, or once that browser is gone. Any other sender's
// is ignored: the helper ends with its browser instead, as Chromium ends it at
// quit or as the closed IPC channel ends it when the browser died. SIGKILL is
// never caught.
#ifndef CMUX_SHIM_HELPER_SIGNAL_POLICY_H_
#define CMUX_SHIM_HELPER_SIGNAL_POLICY_H_

#include <signal.h>
#include <unistd.h>

namespace cmux_shim {

// The browser process this helper started under (0 before the install).
inline pid_t& HelperBrowserPid() {
  static pid_t pid = 0;
  return pid;
}

// True when a helper whose browser is `browser` (now `current_parent` is its
// parent) obeys a quit signal from `sender` (si_pid; 0 for the kernel or a
// terminal). Pure, for the tests.
inline bool HelperObeysQuitSignal(pid_t sender, pid_t self, pid_t browser, pid_t current_parent) {
  if (browser <= 0) return true;              // not installed: the default
  if (current_parent != browser) return true;  // the browser is gone
  return sender == browser || sender == self;
}

inline void HelperQuitSignalHandler(int sig, siginfo_t* info, void*) {
  // Async-signal-safe only: getpid, getppid, sigaction, raise.
  pid_t sender = info ? info->si_pid : 0;
  if (!HelperObeysQuitSignal(sender, getpid(), HelperBrowserPid(), getppid())) return;
  struct sigaction dfl = {};
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  sigaction(sig, &dfl, nullptr);
  // Blocked while this handler runs; delivered with the default action (the
  // helper ends by `sig`, as before) when it returns.
  raise(sig);
}

// The signals a quit sends to a whole group or by process name.
inline constexpr int kHelperQuitSignals[] = {SIGTERM, SIGINT, SIGHUP};

// Installs the rule for this process, its parent now as its browser. Call it
// in a helper after Chromium reset its signals (CefApp::
// OnBeforeCommandLineProcessing runs in BasicStartupComplete, after
// SetupSignalHandlers). A process launchd already owns (a double-forked one,
// such as a crash handler) has no browser to wait for and keeps the defaults.
// Returns false when a sigaction failed.
inline bool InstallHelperQuitSignalPolicy() {
  pid_t parent = getppid();
  if (parent <= 1) return true;
  HelperBrowserPid() = parent;
  struct sigaction action = {};
  action.sa_sigaction = HelperQuitSignalHandler;
  action.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&action.sa_mask);
  bool ok = true;
  for (int sig : kHelperQuitSignals) ok = sigaction(sig, &action, nullptr) == 0 && ok;
  return ok;
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_HELPER_SIGNAL_POLICY_H_

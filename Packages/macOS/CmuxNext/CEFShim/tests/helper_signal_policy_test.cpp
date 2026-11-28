// Checks cmux_shim's helper quit-signal rule (CEFShim/src/helper_signal_policy.h)
// with real processes: a helper ignores SIGTERM, SIGINT and SIGHUP from anyone
// but its browser while that browser lives, so `pkill`, `killall` or Ctrl-C to
// the app's group no longer ends the built-in uBlock Origin's renderer before
// the app (scripts/cmux-next/test-shim-helper-signals-cpp.sh).
#include <signal.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <iostream>

#include "../src/helper_signal_policy.h"

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const char* what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

static void Nap(long ms) {
  struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
  nanosleep(&ts, nullptr);
}

// A helper: installs the rule under its parent, says so on `ready`, then idles.
[[noreturn]] static void RunHelper(int ready) {
  bool ok = cmux_shim::InstallHelperQuitSignalPolicy();
  char byte = ok ? 'y' : 'n';
  (void)!write(ready, &byte, 1);
  close(ready);
  for (;;) pause();
}

static bool WaitReady(int fd) {
  char byte = 0;
  bool ok = read(fd, &byte, 1) == 1 && byte == 'y';
  close(fd);
  return ok;
}

// Sends `sig` to `target` from a separate process (not the helper's browser).
static void SendFromStranger(pid_t target, int sig) {
  pid_t stranger = fork();
  if (stranger == 0) {
    kill(target, sig);
    _exit(0);
  }
  int status = 0;
  waitpid(stranger, &status, 0);
}

// True when our child `pid` ended by `sig` within about 2 s; false if it still runs.
static bool EndsBy(pid_t pid, int sig) {
  for (int i = 0; i < 200; ++i) {
    int status = 0;
    pid_t got = waitpid(pid, &status, WNOHANG);
    if (got == pid) return WIFSIGNALED(status) && WTERMSIG(status) == sig;
    Nap(10);
  }
  return false;
}

static bool StillRuns(pid_t pid) {
  Nap(200);
  int status = 0;
  return waitpid(pid, &status, WNOHANG) == 0;
}

static void PureRule() {
  using cmux_shim::HelperObeysQuitSignal;
  Expect(HelperObeysQuitSignal(100, 200, 100, 100), "the browser's own signal is obeyed");
  Expect(HelperObeysQuitSignal(200, 200, 100, 100), "the helper's own signal is obeyed");
  Expect(!HelperObeysQuitSignal(300, 200, 100, 100), "a stranger's signal is ignored while the browser lives");
  Expect(!HelperObeysQuitSignal(0, 200, 100, 100), "a terminal's (kernel) signal is ignored while the browser lives");
  Expect(HelperObeysQuitSignal(300, 200, 100, 1), "any signal is obeyed once the browser is gone");
  Expect(HelperObeysQuitSignal(300, 200, 0, 1), "without the install, the default");
}

static void BrowserAlive(int sig, const char* stranger_case, const char* browser_case) {
  int pipe_fds[2];
  if (pipe(pipe_fds) != 0) return Expect(false, "pipe");
  pid_t helper = fork();
  if (helper == 0) {
    close(pipe_fds[0]);
    RunHelper(pipe_fds[1]);
  }
  close(pipe_fds[1]);
  Expect(WaitReady(pipe_fds[0]), "the helper installed the rule");
  SendFromStranger(helper, sig);
  Expect(StillRuns(helper), stranger_case);
  kill(helper, sig);
  Expect(EndsBy(helper, sig), browser_case);
  kill(helper, SIGKILL);
  waitpid(helper, nullptr, WNOHANG);
}

// A browser that starts a helper and then dies: the helper obeys anyone after.
static void BrowserGone() {
  int pipe_fds[2];
  int pid_fds[2];
  if (pipe(pipe_fds) != 0 || pipe(pid_fds) != 0) return Expect(false, "pipe");
  pid_t browser = fork();
  if (browser == 0) {
    pid_t helper = fork();
    if (helper == 0) {
      close(pipe_fds[0]);
      RunHelper(pipe_fds[1]);
    }
    (void)!write(pid_fds[1], &helper, sizeof(helper));
    char byte = 0;
    close(pipe_fds[1]);
    bool ok = read(pipe_fds[0], &byte, 1) == 1 && byte == 'y';
    _exit(ok ? 0 : 1);
  }
  close(pipe_fds[0]);
  close(pipe_fds[1]);
  close(pid_fds[1]);
  pid_t helper = 0;
  bool read_pid = read(pid_fds[0], &helper, sizeof(helper)) == sizeof(helper);
  close(pid_fds[0]);
  int status = 0;
  waitpid(browser, &status, 0);
  Expect(read_pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, "the gone browser's helper installed the rule");
  if (!read_pid || helper <= 0) return;
  kill(helper, SIGTERM);
  bool ended = false;
  for (int i = 0; i < 200 && !ended; ++i) {
#if defined(__linux__)
    // This process is the orphan's subreaper (main), so it reaps it here; a
    // container's pid 1 may never reap, which would leave a zombie kill(0) sees.
    int helper_status = 0;
    ended = waitpid(helper, &helper_status, WNOHANG) == helper;
#else
    ended = kill(helper, 0) != 0 && errno == ESRCH;  // launchd reaps it
#endif
    if (!ended) Nap(10);
  }
  Expect(ended, "a helper whose browser is gone obeys SIGTERM from anyone");
  if (!ended) kill(helper, SIGKILL);
}

int main() {
#if defined(__linux__)
  prctl(PR_SET_CHILD_SUBREAPER, 1);
#endif
  PureRule();
  BrowserAlive(SIGTERM, "a stranger's SIGTERM (pkill, killall) leaves the helper running",
               "the browser's SIGTERM ends the helper by SIGTERM");
  BrowserAlive(SIGINT, "a stranger's SIGINT (Ctrl-C to the group) leaves the helper running",
               "the browser's SIGINT ends the helper by SIGINT");
  BrowserAlive(SIGHUP, "a stranger's SIGHUP leaves the helper running",
               "the browser's SIGHUP ends the helper by SIGHUP");
  BrowserGone();
  std::cout << g_cases << " cases, " << g_failures << " failures\n";
  return g_failures == 0 ? 0 : 1;
}

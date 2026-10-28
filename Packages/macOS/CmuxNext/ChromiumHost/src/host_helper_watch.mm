// HelperExitWatcher (host_helper_exits.h): the host's children through a
// kqueue, off the main thread. NOTE_FORK on the host fires when Chromium
// starts a helper (posix_spawn counts), a rescan of the host's children
// follows each new one with NOTE_EXEC | NOTE_EXIT | NOTE_EXITSTATUS, and the
// exit event carries the wait status before Chromium reaps the child. No
// polling: the kqueue's descriptor is a read source of the watcher's queue,
// user-initiated as cmux's cef-children queue: it must add NOTE_EXIT on a new
// helper before Chromium reaps it (plans/cmux-next/threading-model.md).
// cmux's CEFChildProcessMonitor.swift watches cmux's own children the same
// way in process.

#include "host_helper_exits.h"

#include <dispatch/dispatch.h>
#include <libproc.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <utility>

namespace cmux_host {
namespace {

// A process's argv (KERN_PROCARGS2); empty when it cannot be read (it ended).
std::vector<std::string> ArgvOf(pid_t pid) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size <= sizeof(int32_t)) return {};
  std::string buffer(size, '\0');
  if (sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0) return {};
  buffer.resize(size);
  return ProcArgs(buffer);
}

std::optional<HelperIdentity> IdentityOf(pid_t pid) {
  return HelperIdentityOf(ArgvOf(pid));
}

}  // namespace

// The watch's state, shared by the watcher and its queue's blocks; the queue's
// blocks alone touch `table` and `kq` after Start.
struct HelperExitWatcher::State {
  explicit State(Report r) : report(std::move(r)) {}

  // Follows `pid` from now on; false when it already ended (and was reaped).
  bool Follow(pid_t pid) {
    struct kevent change;
    EV_SET(&change, static_cast<uintptr_t>(pid), EVFILT_PROC, EV_ADD | EV_CLEAR, NOTE_EXEC | NOTE_EXIT | NOTE_EXITSTATUS,
           0, nullptr);
    if (kevent(kq, &change, 1, nullptr, 0, nullptr) != 0) return false;
    table.Watch(pid, IdentityOf(pid));
    return true;
  }

  // Follows each child of the host that is not followed yet.
  void Rescan() {
    const pid_t self = getpid();
    const int count = proc_listchildpids(self, nullptr, 0);
    if (count <= 0) return;
    std::vector<pid_t> pids(static_cast<size_t>(count) + 16);
    const int filled = proc_listchildpids(self, pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (filled <= 0) return;
    // A count on current macOS (bytes on older ones): whichever fits the buffer.
    pids.resize(std::min(static_cast<size_t>(filled), pids.size()));
    for (const pid_t pid : pids) {
      if (pid > 0 && !table.Watches(pid)) Follow(pid);
    }
  }

  // Every event the kqueue holds now; the read source fires again while more wait.
  void Drain() {
    struct kevent events[16];
    const struct timespec zero = {0, 0};
    const int count = kevent(kq, nullptr, 0, events, 16, &zero);
    bool forked = false;
    const pid_t self = getpid();
    for (int i = 0; i < count; ++i) {
      const auto pid = static_cast<pid_t>(events[i].ident);
      if (pid == self) {
        forked = forked || (events[i].fflags & NOTE_FORK) != 0;
        continue;
      }
      if ((events[i].fflags & NOTE_EXEC) != 0) table.Execed(pid, IdentityOf(pid));
      if ((events[i].fflags & NOTE_EXIT) != 0) {
        if (std::optional<HelperExit> ended = table.Exited(pid, static_cast<int32_t>(events[i].data))) report(*ended);
      }
    }
    if (forked) Rescan();
  }

  Report report;
  int kq = -1;
  HelperTable table;
  dispatch_source_t source = nullptr;
};

HelperExitWatcher::HelperExitWatcher(Report report) : state_(std::make_shared<State>(std::move(report))) {}

HelperExitWatcher::~HelperExitWatcher() {
  if (state_->source == nullptr) return;
  // The cancel handler closes the kqueue on the queue, after any drain in flight.
  dispatch_source_cancel(state_->source);
  dispatch_release(state_->source);
  state_->source = nullptr;
}

bool HelperExitWatcher::Start() {
  if (state_->source != nullptr) return true;
  const int kq = kqueue();
  if (kq < 0) {
    fprintf(stderr, "cmux-chromium-host: helper watch: kqueue failed: %d\n", errno);
    return false;
  }
  struct kevent fork_watch;
  EV_SET(&fork_watch, static_cast<uintptr_t>(getpid()), EVFILT_PROC, EV_ADD | EV_CLEAR, NOTE_FORK, 0, nullptr);
  if (kevent(kq, &fork_watch, 1, nullptr, 0, nullptr) != 0) {
    fprintf(stderr, "cmux-chromium-host: helper watch: NOTE_FORK failed: %d\n", errno);
    close(kq);
    return false;
  }
  state_->kq = kq;
  dispatch_queue_t queue = dispatch_queue_create(
      "com.cmuxterm.chromium-host.helper-exits",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, static_cast<uintptr_t>(kq), 0, queue);
  const std::shared_ptr<State> state = state_;
  dispatch_source_set_event_handler(source, ^{
    state->Drain();
  });
  dispatch_source_set_cancel_handler(source, ^{
    close(state->kq);
    state->kq = -1;
  });
  state_->source = source;
  // The children Chromium started before the watch (its GPU and network service, at initialize).
  dispatch_async(queue, ^{
    state->Rescan();
  });
  dispatch_resume(source);
  dispatch_release(queue);  // the source and the block hold it
  return true;
}

}  // namespace cmux_host

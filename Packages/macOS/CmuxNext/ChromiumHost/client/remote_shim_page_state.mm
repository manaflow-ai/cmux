// The remote shim's page state exports (remote_shim_page_state.h, task
// p01-process-093). Plain C++ (no Objective-C), so
// tests/remote_shim_page_state_test.cpp compiles it on any machine.

#include "remote_shim_page_state.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <unordered_map>

#include "host_page_state.h"  // kMaxPageStateEntries, kMaxPageStateBytes

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace cmux_remote::page_state {
namespace {

// Like Chrome's DCHECK_CALLED_ON_VALID_SEQUENCE: the state below has no lock
// because only the main thread touches it.
void AssertMainThread() {
#if defined(__APPLE__)
  assert(pthread_main_np() != 0);
#elif defined(__linux__)
  assert(syscall(SYS_gettid) == getpid());
#endif
}

class PageStates {
 public:
  void Attach(const Transport* transport) { transport_ = transport; }

  void Detach() {
    transport_ = nullptr;
    watched_.clear();
  }

  // As the fork's: 1 when watching, 0 for no host, a refused send or a stop
  // (fn NULL), which also drops the kept states.
  int Watch(int browser_id, WatchFn fn, void* context) {
    if (fn == nullptr) {
      if (watched_.erase(browser_id) > 0) Send(browser_id, false);
      return 0;
    }
    auto found = watched_.find(browser_id);
    if (found != watched_.end()) {
      found->second.fn = fn;
      found->second.context = context;
      return 1;
    }
    if (!Send(browser_id, true)) return 0;
    watched_[browser_id] = Watched{fn, context, {}};
    return 1;
  }

  // A malloc'd copy (cmux_shim_free frees it), NULL for no kept state.
  char* Read(int browser_id, int index) const {
    auto watched = watched_.find(browser_id);
    if (watched == watched_.end()) return nullptr;
    auto state = watched->second.states.find(index);
    if (state == watched->second.states.end()) return nullptr;
    const std::string& bytes = state->second;
    auto* out = static_cast<char*>(std::malloc(bytes.size() + 1));
    if (out == nullptr) return nullptr;
    std::memcpy(out, bytes.data(), bytes.size());
    out[bytes.size()] = '\0';
    return out;
  }

  bool Deliver(int browser_id, int index, bool has_state, const std::string& state) {
    auto watched = watched_.find(browser_id);
    if (watched == watched_.end() || index < 0 || index >= cmux_host::kMaxPageStateEntries) return false;
    // The host never sends more; a longer one is kept as none, never cut.
    if (has_state && !state.empty() && state.size() <= cmux_host::kMaxPageStateBytes) {
      watched->second.states[index] = state;
    } else {
      watched->second.states.erase(index);
    }
    // A copy: fn may stop or replace its own watch.
    const WatchFn fn = watched->second.fn;
    void* const context = watched->second.context;
    fn(context, browser_id, index);
    return true;
  }

  void BrowserClosed(int browser_id) { watched_.erase(browser_id); }

  size_t KeptStates() const {
    size_t count = 0;
    for (const auto& [browser, watched] : watched_) count += watched.states.size();
    return count;
  }

 private:
  struct Watched {
    WatchFn fn = nullptr;
    void* context = nullptr;
    // By entry index: at most kMaxPageStateEntries of kMaxPageStateBytes each.
    std::unordered_map<int, std::string> states;
  };

  bool Send(int browser_id, bool watching) {
    return transport_ != nullptr && transport_->send_watch(transport_->context, browser_id, watching);
  }

  const Transport* transport_ = nullptr;
  std::unordered_map<int, Watched> watched_;  // by browser id
};

// One per loaded dylib: the C ABI has no handle to carry an instance.
PageStates& States() {
  static PageStates states;
  return states;
}

}  // namespace

void Attach(const Transport* transport) {
  AssertMainThread();
  States().Attach(transport);
}

void Detach() {
  AssertMainThread();
  States().Detach();
}

bool Deliver(int browser_id, int index, bool has_state, const std::string& state) {
  AssertMainThread();
  return States().Deliver(browser_id, index, has_state, state);
}

void BrowserClosed(int browser_id) {
  AssertMainThread();
  States().BrowserClosed(browser_id);
}

size_t KeptStates() {
  AssertMainThread();
  return States().KeptStates();
}

}  // namespace cmux_remote::page_state

extern "C" {

CMUX_SHIM_EXPORT int cmux_shim_tab_page_state_watch(int browser_id,
                                                    void (*fn)(void* context, int browser_id, int index),
                                                    void* context) {
  cmux_remote::page_state::AssertMainThread();
  return cmux_remote::page_state::States().Watch(browser_id, fn, context);
}

CMUX_SHIM_EXPORT char* cmux_shim_tab_entry_page_state(int browser_id, int index) {
  cmux_remote::page_state::AssertMainThread();
  return cmux_remote::page_state::States().Read(browser_id, index);
}

}  // extern "C"

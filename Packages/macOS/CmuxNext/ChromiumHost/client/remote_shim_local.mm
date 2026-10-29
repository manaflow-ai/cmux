// The remote shim's local class (remote_shim_local.h, task 014b): the
// function-pointer exports, kept in the client and fed by the host's pushes.
// Plain C++ (no Objective-C), so tests/remote_shim_local_test.cpp compiles it
// on any machine (scripts/cmux-next/tests/remote-shim-local.test.sh).

#include "remote_shim_local.h"

#include <cassert>
#include <unordered_map>

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace cmux_remote {
namespace {

// Like Chrome's DCHECK_CALLED_ON_VALID_SEQUENCE: the state below has no lock
// because only the main thread touches it.
// Linux has it too, so the test there refuses a call from another thread.
void AssertMainThread() {
#if defined(__APPLE__)
  assert(pthread_main_np() != 0);
#elif defined(__linux__)
  assert(syscall(SYS_gettid) == getpid());
#endif
}

// A callback and the context it was given with.
template <typename Fn>
struct Callback {
  Fn fn = nullptr;
  void* context = nullptr;
};

class LocalClient {
 public:
  void Attach(const LocalTransport* transport) {
    transport_ = transport;
    SyncDragSourceHandler();
  }

  void Detach() {
    transport_ = nullptr;
    drag_sent_installed_ = false;
    text_input_.clear();
    // Swapped out first: a reveal that done starts finds no host and returns 0.
    std::unordered_map<uint32_t, Callback<cmux_shim_password_reveal_fn>> ended;
    ended.swap(reveals_);
    for (auto& [token, done] : ended) done.fn(done.context, nullptr, 0);
  }

  int TextInputWatch(int browser_id, TextInputFn fn, void* context) {
    if (fn == nullptr) {
      if (text_input_.erase(browser_id) > 0) SendTextInputWatch(browser_id, false);
      return 1;
    }
    const bool watched = text_input_.count(browser_id) > 0;
    if (!watched && !SendTextInputWatch(browser_id, true)) return 0;
    text_input_[browser_id] = {fn, context};
    return 1;
  }

  void SetDragSourceHandler(DragSourceFn fn, void* context) {
    drag_ = {fn, context};
    SyncDragSourceHandler();
  }

  int PasswordReveal(const char* profile_cache_path, const char* id, cmux_shim_password_reveal_fn done, void* ctx) {
    // The in-process shim's own checks; the host refuses the rest in its REPLY.
    if (profile_cache_path == nullptr || *profile_cache_path == '\0' || id == nullptr || *id == '\0' ||
        done == nullptr || transport_ == nullptr) {
      return 0;
    }
    const uint32_t token = transport_->next_token(transport_->context);
    if (!transport_->send_password_reveal(transport_->context, token, profile_cache_path, id)) return 0;
    reveals_[token] = {done, ctx};
    return 1;
  }

  bool DeliverTextInputState(int browser_id, const void* state) {
    auto it = text_input_.find(browser_id);
    if (it == text_input_.end()) return false;
    // A copy: fn may stop or replace its own watch.
    const Callback<TextInputFn> watch = it->second;
    watch.fn(watch.context, browser_id, state);
    return true;
  }

  bool DeliverDragStart(int browser_id, const void* drag) {
    if (drag_.fn == nullptr) return false;
    const Callback<DragSourceFn> handler = drag_;
    handler.fn(handler.context, browser_id, drag);
    return true;
  }

  bool DeliverPasswordReveal(uint32_t token, const char* password, size_t length) {
    auto it = reveals_.find(token);
    if (it == reveals_.end()) return false;
    // done runs exactly once (the header's contract): erased before it runs.
    const Callback<cmux_shim_password_reveal_fn> done = it->second;
    reveals_.erase(it);
    done.fn(done.context, password, password != nullptr ? length : 0);
    return true;
  }

 private:
  bool SendTextInputWatch(int browser_id, bool watching) {
    return transport_ != nullptr && transport_->send_text_input_watch(transport_->context, browser_id, watching);
  }

  // Sends installed/removed when it differs from what the host last took; a
  // refused send leaves the difference, so the next set or Attach sends it.
  void SyncDragSourceHandler() {
    const bool installed = drag_.fn != nullptr;
    if (installed == drag_sent_installed_ || transport_ == nullptr) return;
    if (transport_->send_drag_source_handler(transport_->context, installed)) drag_sent_installed_ = installed;
  }

  const LocalTransport* transport_ = nullptr;
  Callback<DragSourceFn> drag_;
  bool drag_sent_installed_ = false;  // what the attached host last took
  std::unordered_map<int, Callback<TextInputFn>> text_input_;                     // by browser id
  std::unordered_map<uint32_t, Callback<cmux_shim_password_reveal_fn>> reveals_;  // by token
};

// One per loaded dylib: the C ABI has no handle to carry an instance, as the
// in-process shim's host() (CEFShim/src/shim_process.mm).
LocalClient& Client() {
  static LocalClient client;
  return client;
}

}  // namespace

void Attach(const LocalTransport* transport) {
  AssertMainThread();
  Client().Attach(transport);
}

void Detach() {
  AssertMainThread();
  Client().Detach();
}

bool DeliverTextInputState(int browser_id, const void* state) {
  AssertMainThread();
  return Client().DeliverTextInputState(browser_id, state);
}

bool DeliverDragStart(int browser_id, const void* drag) {
  AssertMainThread();
  return Client().DeliverDragStart(browser_id, drag);
}

bool DeliverPasswordReveal(uint32_t token, const char* password, size_t length) {
  AssertMainThread();
  return Client().DeliverPasswordReveal(token, password, length);
}

}  // namespace cmux_remote

extern "C" {

// The host posts input to its own user-input queue (tasks 041 and 042); no
// task of cmux's runs on Chromium's UI thread. 0, as when the fork lacks the
// call: fn never runs, so the caller still owns context. Any thread.
CMUX_SHIM_EXPORT int cmux_shim_post_user_input_task(void (*fn)(void* context), void* context) {
  (void)fn;
  (void)context;
  return 0;
}

CMUX_SHIM_EXPORT int cmux_shim_browser_text_input_watch(int browser_id,
                                                        void (*fn)(void* context, int browser_id, const void* state),
                                                        void* context) {
  cmux_remote::AssertMainThread();
  return cmux_remote::Client().TextInputWatch(browser_id, fn, context);
}

// A hosted page's composition rects already come with its TEXT_INPUT_STATE
// (task 044: cmux_shim_browser_text_input_watch's state carries one rect per
// character), so this second watch is not served. 0, as when the fork lacks
// the call (API below 31): fn never runs.
CMUX_SHIM_EXPORT int cmux_shim_browser_composition_bounds_watch(int browser_id,
                                                                void (*fn)(void* context, int browser_id,
                                                                           const void* bounds),
                                                                void* context) {
  (void)browser_id;
  (void)fn;
  (void)context;
  return 0;
}

CMUX_SHIM_EXPORT void cmux_shim_set_drag_source_handler(void (*fn)(void* context, int browser_id, const void* drag),
                                                        void* context) {
  cmux_remote::AssertMainThread();
  cmux_remote::Client().SetDragSourceHandler(fn, context);
}

CMUX_SHIM_EXPORT int cmux_shim_password_reveal(const char* profile_cache_path, const char* id,
                                               cmux_shim_password_reveal_fn done, void* ctx) {
  cmux_remote::AssertMainThread();
  return cmux_remote::Client().PasswordReveal(profile_cache_path, id, done, ctx);
}

}  // extern "C"

// The remote shim's local class (remote_shim_local.h, task 014b): the
// function-pointer exports, kept in the client and fed by the host's pushes.
// Plain C++ (no Objective-C), so tests/remote_shim_local_test.cpp compiles it
// on any machine (scripts/cmux-next/tests/remote-shim-local.test.sh).

#include "remote_shim_local.h"

#include <cassert>
#include <unordered_map>

#if defined(__APPLE__)
#include <pthread.h>
#endif

namespace cmux_remote {
namespace {

// Like Chrome's DCHECK_CALLED_ON_VALID_SEQUENCE: the state below has no lock
// because only the main thread touches it.
void AssertMainThread() {
#if defined(__APPLE__)
  assert(pthread_main_np() != 0);
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
    if (drag_.fn != nullptr) SendDragSourceHandler(true);
  }

  void Detach() {
    transport_ = nullptr;
    initialize_sent_ = false;
    text_input_.clear();
    // Swapped out first: a reveal that done starts finds no host and returns 0.
    std::unordered_map<uint32_t, Callback<cmux_shim_password_reveal_fn>> ended;
    ended.swap(reveals_);
    for (auto& [token, done] : ended) done.fn(done.context, nullptr, 0);
  }

  int Initialize(const InitializeRequest& request, void* ctx, cmux_shim_event_fn event) {
    // CefInitialize runs once per host; the next host needs Detach first.
    if (initialize_sent_ || transport_ == nullptr) return 0;
    if (!transport_->send_initialize(transport_->context, request)) return 0;
    initialize_sent_ = true;
    event_ = {event, ctx};
    return 1;
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
    const bool was_installed = drag_.fn != nullptr;
    drag_ = {fn, context};
    if (was_installed != (fn != nullptr)) SendDragSourceHandler(fn != nullptr);
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

  bool DeliverEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1, const char* s2) {
    if (event_.fn == nullptr) return false;
    event_.fn(event_.context, kind, browser_id, request, a, b, s1 != nullptr ? s1 : "", s2 != nullptr ? s2 : "");
    return true;
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

  bool SendDragSourceHandler(bool installed) {
    return transport_ != nullptr && transport_->send_drag_source_handler(transport_->context, installed);
  }

  const LocalTransport* transport_ = nullptr;
  bool initialize_sent_ = false;
  Callback<cmux_shim_event_fn> event_;
  Callback<DragSourceFn> drag_;
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

bool DeliverEvent(int kind, int browser_id, int request, int64_t a, int64_t b, const char* s1, const char* s2) {
  AssertMainThread();
  return Client().DeliverEvent(kind, browser_id, request, a, b, s1, s2);
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

// The host's Chromium runs CefInitialize (task 013). schedule never runs: the
// host runs its own message loop, so there is no pump (task 034). key is not
// kept: keys route cmux-first and come back as KEY_UNHANDLED (task 030).
// Returns 1 when INITIALIZE is sent; success is CONTEXT_INITIALIZED later.
CMUX_SHIM_EXPORT int cmux_shim_initialize(const char* framework_dir, const char* main_bundle_path,
                                          const char* subprocess_path, const char* root_cache_path,
                                          const char* log_file, int log_severity, const char* locale,
                                          const char* accept_languages, const char* const* switches, void* ctx,
                                          cmux_shim_schedule_fn schedule, cmux_shim_event_fn event,
                                          cmux_shim_key_fn key) {
  cmux_remote::AssertMainThread();
  (void)schedule;
  (void)key;
  const cmux_remote::InitializeRequest request{framework_dir, main_bundle_path, subprocess_path,
                                               root_cache_path, log_file, log_severity,
                                               locale, accept_languages, switches};
  return cmux_remote::Client().Initialize(request, ctx, event);
}

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

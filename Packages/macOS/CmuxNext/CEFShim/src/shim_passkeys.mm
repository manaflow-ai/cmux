// Profile (Touch ID) passkeys for the Passwords page (plans/cmux-next/passwords.md
// 1.4): the fork's cmux_profile_passkeys_list and cmux_profile_passkey_delete
// (API 18). Metadata only: relying party, credential id and user names. No key
// material crosses this file.

#include <atomic>
#include <string>

#include "include/cef_cookie.h"
#include "include/base/cef_callback.h"
#include "include/cef_request_context.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// One passkey request, kept alive until it replied exactly once.
//
// Contract with the fork (include/cef_cmux.h, API 18): the callback runs
// once, on the UI thread, if and only if the call returned 1, and the fork
// keeps the JSON string alive during the callback (it is copied here; the
// shim frees nothing of the fork's). The shim does not rely on that: a reply
// from another thread hops to the UI thread before Emit (UI thread only),
// and a second callback, or a callback from a call that returned 0, is
// ignored, so there is never a double reply or a double Release. A fork that
// returns 1 and never calls back leaks this request; Swift's timeout
// (CEFEngine.passkeyTimeout, 30 s) ends the wait.
class PasskeyRequest : public CefBaseRefCounted {
 public:
  PasskeyRequest(std::string path, std::string credential_id, int reply)
      : path_(std::move(path)), credential_id_(std::move(credential_id)), reply_(reply) {}

  // Runs once the profile's storage is initialized (also for a profile no tab opened yet).
  void Start() {
    AddRef();  // Released by the one reply.
    int started = 0;
    if (credential_id_.empty()) {
      started = fork_api().profile_passkeys_list ? fork_api().profile_passkeys_list(path_.c_str(), &PasskeyRequest::Listed, this) : 0;
    } else {
      started = fork_api().profile_passkey_delete
                    ? fork_api().profile_passkey_delete(path_.c_str(), credential_id_.c_str(), &PasskeyRequest::Deleted, this)
                    : 0;
    }
    if (!started) Finish(0, std::string());
  }

  static void Listed(void* context, const char* json) {
    static_cast<PasskeyRequest*>(context)->Finish(json ? 1 : 0, json ? std::string(json) : std::string());
  }

  static void Deleted(void* context, int deleted) {
    static_cast<PasskeyRequest*>(context)->Finish(deleted == 1 ? 1 : 0, std::string());
  }

 private:
  // The one reply: later calls are ignored; off the UI thread it hops there first.
  void Finish(int64_t value, std::string json) {
    if (finished_.exchange(true)) return;
    if (!CefCurrentlyOn(TID_UI)) {
      CefPostTask(TID_UI, base::BindOnce(&PasskeyRequest::Reply, CefRefPtr<PasskeyRequest>(this), value, std::move(json)));
      return;
    }
    Reply(value, std::move(json));
  }

  void Reply(int64_t value, std::string json) {
    Emit(CMUX_SHIM_REPLY, 0, reply_, value, 0, json);
    Release();  // The reference Start took.
  }

  std::string path_;
  std::string credential_id_;
  int reply_;
  std::atomic<bool> finished_{false};
  IMPLEMENT_REFCOUNTING(PasskeyRequest);
};

// The cookie manager's ready callback is the signal that the profile behind
// the request context is initialized (the same signal the password import uses).
class StartPasskeysWhenReady : public CefCompletionCallback {
 public:
  explicit StartPasskeysWhenReady(CefRefPtr<PasskeyRequest> request) : request_(request) {}
  void OnComplete() override { request_->Start(); }

 private:
  CefRefPtr<PasskeyRequest> request_;
  IMPLEMENT_REFCOUNTING(StartPasskeysWhenReady);
};

int StartPasskeyRequest(const char* profile_cache_path, std::string credential_id, int reply) {
  if (!profile_cache_path || !*profile_cache_path || IsOffTheRecordKey(profile_cache_path)) return 0;
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  CefRefPtr<PasskeyRequest> request = new PasskeyRequest(profile_cache_path, std::move(credential_id), reply);
  context->GetCookieManager(new StartPasskeysWhenReady(request));
  return 1;
}

}  // namespace

extern "C" {

int cmux_shim_passkeys_available(void) {
  // API 18 and both calls: a fork that has the symbols under an older version is not trusted.
  return fork_api().version >= 18 && fork_api().profile_passkeys_list && fork_api().profile_passkey_delete ? 1 : 0;
}

int cmux_shim_passkeys_list(const char* profile_cache_path, int reply) {
  if (!fork_api().profile_passkeys_list) return 0;
  return StartPasskeyRequest(profile_cache_path, std::string(), reply);
}

int cmux_shim_passkey_delete(const char* profile_cache_path, const char* credential_id, int reply) {
  if (!fork_api().profile_passkey_delete || !credential_id || !*credential_id) return 0;
  return StartPasskeyRequest(profile_cache_path, credential_id, reply);
}

}  // extern "C"

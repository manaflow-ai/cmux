// Profile (Touch ID) passkeys for the Passwords page (plans/cmux-next/passwords.md
// 1.4): the fork's cmux_profile_passkeys_list and cmux_profile_passkey_delete
// (API 18). Metadata only: relying party, credential id and user names. No key
// material crosses this file.
//
// iCloud Keychain requests of a helper-app browser process (fork API 31,
// cmux_set_webauthn_platform_handler; plans/cmux-next/passkeys.md 3.9): the
// fork's requests become WEBAUTHN_PLATFORM_REQUEST and _CANCEL events, and
// cmux's answers go back by token. The request and answer JSON hold ceremony
// secrets (client data, PRF inputs and outputs, signatures): this file never
// logs them.

#include <string>

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// One passkey request, kept alive until the fork replies.
class PasskeyRequest : public CefBaseRefCounted {
 public:
  PasskeyRequest(std::string path, std::string credential_id, int reply)
      : path_(std::move(path)), credential_id_(std::move(credential_id)), reply_(reply) {}

  // Runs once the profile's storage is initialized (also for a profile no tab opened yet).
  void Start() {
    AddRef();
    int started = 0;
    if (credential_id_.empty()) {
      started = fork_api().profile_passkeys_list ? fork_api().profile_passkeys_list(path_.c_str(), &PasskeyRequest::Listed, this) : 0;
    } else {
      started = fork_api().profile_passkey_delete
                    ? fork_api().profile_passkey_delete(path_.c_str(), credential_id_.c_str(), &PasskeyRequest::Deleted, this)
                    : 0;
    }
    if (!started) {
      Emit(CMUX_SHIM_REPLY, 0, reply_, 0, 0);
      Release();
    }
  }

  static void Listed(void* context, const char* json) {
    auto* request = static_cast<PasskeyRequest*>(context);
    Emit(CMUX_SHIM_REPLY, 0, request->reply_, json ? 1 : 0, 0, json ? std::string(json) : std::string());
    request->Release();
  }

  static void Deleted(void* context, int deleted) {
    auto* request = static_cast<PasskeyRequest*>(context);
    Emit(CMUX_SHIM_REPLY, 0, request->reply_, deleted == 1 ? 1 : 0, 0);
    request->Release();
  }

 private:
  std::string path_;
  std::string credential_id_;
  int reply_;
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

WebAuthnPlatformSetter& webauthn_platform() {
  static WebAuthnPlatformSetter setter;
  return setter;
}

// UI thread, from a posted task (the fork's contract).
void OnWebAuthnPlatformRequest(void*, const ForkWebAuthnPlatformRequest* request) {
  if (WebAuthnPlatformRequestUsable(request)) {
    Emit(CMUX_SHIM_WEBAUTHN_PLATFORM_REQUEST, request->browser_id, request->operation, request->token, 0, request->json);
    return;
  }
  // A request cmux cannot read never waits: Chromium rejects it now.
  int64_t token = 0;
  if (WebAuthnPlatformToken(request, &token) && fork_api().webauthn_platform_reply) {
    fork_api().webauthn_platform_reply(token, nullptr);
  }
}

void OnWebAuthnPlatformCancel(void*, int64_t token) {
  Emit(CMUX_SHIM_WEBAUTHN_PLATFORM_CANCEL, 0, 0, token);
}

}  // namespace

extern "C" {

int cmux_shim_passkeys_available(void) {
  return fork_api().profile_passkeys_list && fork_api().profile_passkey_delete ? 1 : 0;
}

int cmux_shim_passkeys_list(const char* profile_cache_path, int reply) {
  if (!fork_api().profile_passkeys_list) return 0;
  return StartPasskeyRequest(profile_cache_path, std::string(), reply);
}

int cmux_shim_passkey_delete(const char* profile_cache_path, const char* credential_id, int reply) {
  if (!fork_api().profile_passkey_delete || !credential_id || !*credential_id) return 0;
  return StartPasskeyRequest(profile_cache_path, credential_id, reply);
}

int cmux_shim_set_webauthn_platform(int permission) {
  WebAuthnPlatformSetter& setter = webauthn_platform();
  setter.set_handler = fork_api().set_webauthn_platform_handler;
  setter.set_permission = fork_api().webauthn_platform_set_permission;
  return setter.Apply(permission, &OnWebAuthnPlatformRequest, &OnWebAuthnPlatformCancel);
}

int cmux_shim_webauthn_platform_reply(int64_t token, const char* json) {
  if (!webauthn_platform().handler_set || !fork_api().webauthn_platform_reply) return 0;
  return fork_api().webauthn_platform_reply(token, json);
}

}  // extern "C"

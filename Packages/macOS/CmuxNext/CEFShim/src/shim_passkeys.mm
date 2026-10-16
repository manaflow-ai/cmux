// Profile (Touch ID) passkeys for the Passwords page (plans/cmux-next/passwords.md
// 1.4): the fork's cmux_profile_passkeys_list and cmux_profile_passkey_delete
// (API 18). Metadata only: relying party, credential id and user names. No key
// material crosses this file.
//
// Also the keychain group of Chromium's macOS platform authenticator
// (plans/cmux-next/passkeys.md K19). On macOS, Chromium answers
// PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() only
// from its profile (Touch ID) authenticator, which needs the
// "<team>.<bundle>.webauthn" group in the signed app's keychain-access-groups;
// iCloud Keychain support does not count. Without the group every cmux build
// answered false, and GitHub showed "This browser or device is reporting
// partial passkey support".

#include <string>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

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

// The ".webauthn" entry of the running app's keychain-access-groups
// entitlement, or "" (unsigned, ad-hoc and DEV builds have none).
std::string WebAuthnGroupFromEntitlements() {
  SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
  if (!task) return std::string();
  CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("keychain-access-groups"), nullptr);
  CFRelease(task);
  std::string group;
  static const std::string kSuffix = ".webauthn";
  if (value && CFGetTypeID(value) == CFArrayGetTypeID()) {
    CFArrayRef groups = static_cast<CFArrayRef>(value);
    for (CFIndex i = 0; i < CFArrayGetCount(groups) && group.empty(); ++i) {
      CFTypeRef item = CFArrayGetValueAtIndex(groups, i);
      if (!item || CFGetTypeID(item) != CFStringGetTypeID()) continue;
      char buffer[256];
      if (!CFStringGetCString(static_cast<CFStringRef>(item), buffer, sizeof(buffer), kCFStringEncodingUTF8)) continue;
      std::string entry(buffer);
      if (entry.size() > kSuffix.size() && entry.compare(entry.size() - kSuffix.size(), kSuffix.size(), kSuffix) == 0) {
        group = entry;
      }
    }
  }
  if (value) CFRelease(value);
  return group;
}

}  // namespace

namespace cmux_shim {

void ConfigureWebAuthnKeychainAccessGroup() {
  // The setter returns int from fork API 19 (void before); the pinned fork is newer.
  if (fork_api().version < 19 || !fork_api().set_webauthn_keychain_access_group) return;
  const std::string group = WebAuthnGroupFromEntitlements();
  if (group.empty()) return;  // Chromium keeps its own group, which no cmux build has
  fork_api().set_webauthn_keychain_access_group(group.c_str());
}

}  // namespace cmux_shim

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

}  // extern "C"

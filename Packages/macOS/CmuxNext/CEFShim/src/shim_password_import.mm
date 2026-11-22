// Browser import (plans/cmux-next/browser.md, "Password import"): hands the
// saved passwords of one source browser profile to the fork's
// cmux_password_import, which adds them to the Chromium password store of a
// cmux profile (encrypted with cmux's own Keychain key; autofill reads it).
// Values pass through memory only: the shim copies them into buffers it
// zeroes when the store has taken them, never into a std::string, a CEF
// value or a log line. The reply carries counts only.

#define __STDC_WANT_LIB_EXT1__ 1  // memset_s
#include <string.h>

#include <cstddef>
#include <memory>
#include <vector>

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// One field copied out of the caller's buffer; zeroed before it is freed.
class SecretField {
 public:
  SecretField(const char* bytes, size_t length) : bytes_(length) {
    if (length > 0 && bytes) memcpy(bytes_.data(), bytes, length);
  }
  ~SecretField() {
    if (!bytes_.empty()) memset_s(bytes_.data(), bytes_.size(), 0, bytes_.size());
  }
  SecretField(const SecretField&) = delete;
  SecretField& operator=(const SecretField&) = delete;
  const char* data() const { return bytes_.data(); }
  size_t size() const { return bytes_.size(); }

 private:
  std::vector<char> bytes_;
};

// The batch, owned until the fork replies (or nothing was started).
class PasswordBatch : public CefBaseRefCounted {
 public:
  PasswordBatch(std::string path, int reply, const cmux_shim_password_entry* entries, int count)
      : path_(std::move(path)), reply_(reply) {
    fields_.reserve(static_cast<size_t>(count) * 4);
    rows_.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      const cmux_shim_password_entry& entry = entries[i];
      const SecretField& url = Keep(entry.url, entry.url_length);
      const SecretField& realm = Keep(entry.signon_realm, entry.signon_realm_length);
      const SecretField& user = Keep(entry.username, entry.username_length);
      const SecretField& password = Keep(entry.password, entry.password_length);
      rows_.push_back({url.data(), url.size(), realm.data(), realm.size(), user.data(), user.size(), password.data(), password.size(),
                       entry.created});
    }
  }

  // Runs once the profile's storage is initialized (also for a profile no tab opened yet).
  void Start() {
    // The fork copies every row into its own store request before it returns,
    // so the copies here are zeroed right after the call, not after the write.
    AddRef();
    const int count = static_cast<int>(rows_.size());
    const int started = fork_api().password_import(path_.c_str(), rows_.data(), count, &PasswordBatch::Done, this);
    rows_.clear();
    fields_.clear();
    if (!started) {
      Reply(0, 0, 0, count);
      Release();
    }
  }

  static void Done(void* context, int added, int duplicate, int conflict, int rejected) {
    auto* batch = static_cast<PasswordBatch*>(context);
    batch->Reply(added, duplicate, conflict, rejected);
    batch->Release();
  }

 private:
  const SecretField& Keep(const char* bytes, size_t length) {
    fields_.push_back(std::make_unique<SecretField>(bytes, length));
    return *fields_.back();
  }

  void Reply(int added, int duplicate, int conflict, int rejected) {
    Emit(CMUX_SHIM_REPLY, 0, reply_, added, 0,
         "{\"added\":" + std::to_string(added) + ",\"duplicate\":" + std::to_string(duplicate) +
             ",\"conflict\":" + std::to_string(conflict) + ",\"rejected\":" + std::to_string(rejected) + "}");
  }

  std::string path_;
  int reply_;
  std::vector<std::unique_ptr<SecretField>> fields_;
  std::vector<cmux_shim_password_entry> rows_;
  IMPLEMENT_REFCOUNTING(PasswordBatch);
};

// The cookie manager's ready callback is the signal that the profile behind
// the request context is initialized, the same as the cookie import uses.
class StartWhenReady : public CefCompletionCallback {
 public:
  explicit StartWhenReady(CefRefPtr<PasswordBatch> batch) : batch_(batch) {}
  void OnComplete() override { batch_->Start(); }

 private:
  CefRefPtr<PasswordBatch> batch_;
  IMPLEMENT_REFCOUNTING(StartWhenReady);
};

}  // namespace

extern "C" {

int cmux_shim_password_entry_size(void) {
  static_assert(offsetof(cmux_shim_password_entry, password) == 48 && offsetof(cmux_shim_password_entry, created) == 64,
                "CEFRuntime+PasswordImport.swift writes these offsets");
  return static_cast<int>(sizeof(cmux_shim_password_entry));
}

int cmux_shim_password_import_available(void) {
  // Never import into a fork that cannot keep imported passwords out of agent-driven tabs.
  return fork_api().password_import && fork_api().tab_set_password_fill ? 1 : 0;
}

int cmux_shim_import_passwords(const char* profile_cache_path, int reply, const cmux_shim_password_entry* entries, int count) {
  if (!fork_api().password_import || !profile_cache_path || !*profile_cache_path || IsOffTheRecordKey(profile_cache_path) ||
      !entries || count <= 0) {
    return 0;
  }
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  // Copied here, so the caller may zero its buffers as soon as this returns.
  CefRefPtr<PasswordBatch> batch = new PasswordBatch(profile_cache_path, reply, entries, count);
  context->GetCookieManager(new StartWhenReady(batch));
  return 1;
}

int cmux_shim_set_password_fill(int browser_id, int enabled) {
  return fork_api().tab_set_password_fill ? fork_api().tab_set_password_fill(browser_id, enabled ? 1 : 0) : 0;
}

}  // extern "C"

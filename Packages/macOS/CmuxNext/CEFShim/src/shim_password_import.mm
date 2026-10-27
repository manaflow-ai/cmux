// Browser import (plans/cmux-next/browser.md, "Password import"): hands the
// saved passwords of one source browser profile to the fork's
// cmux_password_import, which adds them to the Chromium password store of a
// cmux profile (encrypted with cmux's own Keychain key; autofill reads it).
// Values pass through memory only: the shim copies them into buffers it
// zeroes when the store has taken them, never into a std::string, a CEF
// value or a log line. The reply carries counts only, and for an import the
// indices of the rows whose sign-in is saved with another password, so the
// app can offer to replace those (cmux_password_import_replace, API 20).

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "password_reveal_relay.h"
#include "shim_internal.h"
#include "unsafe_buffers.h"

using namespace cmux_shim;

namespace {

// One field copied out of the caller's buffer; zeroed before it is freed.
class SecretField {
 public:
  SecretField(const char* bytes, size_t length) {
    if (!bytes) {
      bytes_.assign(length, '\0');
      return;
    }
    const std::string_view field(bytes, length);
    bytes_.assign(field.begin(), field.end());
  }
  ~SecretField() { ZeroSecret(bytes_); }
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
  enum class Mode { kImport, kReplace };

  PasswordBatch(Mode mode, std::string path, int reply, const cmux_shim_password_entry* entries, int count)
      : mode_(mode), path_(std::move(path)), reply_(reply) {
    fields_.reserve(static_cast<size_t>(count) * 4);
    rows_.reserve(static_cast<size_t>(count));
    // SAFETY: cmux_shim_import_passwords / cmux_shim_replace_passwords
    // (cmux_cef_shim.h) pass `count` entries at `entries`, alive for the call
    // that builds this batch (StartBatch refused NULL and a count <= 0).
    for (const cmux_shim_password_entry& entry : UNSAFE_BUFFERS(SpanFromCArray(entries, count))) {
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
    const ForkApi& api = fork_api();
    int started = 0;
    if (mode_ == Mode::kReplace) {
      started = api.password_import_replace(path_.c_str(), rows_.data(), count, &PasswordBatch::Replaced, this);
    } else if (api.password_import_v2) {
      started = api.password_import_v2(path_.c_str(), rows_.data(), count, &PasswordBatch::Imported, this);
    } else {
      started = api.password_import(path_.c_str(), rows_.data(), count, &PasswordBatch::Done, this);
    }
    rows_.clear();
    fields_.clear();
    if (!started) {
      if (mode_ == Mode::kReplace) {
        ReplyReplaced(0, 0, count);
      } else {
        Reply(0, 0, 0, count, nullptr, 0);
      }
      Release();
    }
  }

  static void Done(void* context, int added, int duplicate, int conflict, int rejected) {
    auto* batch = static_cast<PasswordBatch*>(context);
    batch->Reply(added, duplicate, conflict, rejected, nullptr, 0);
    batch->Release();
  }

  // API 20: the fork owns `conflict_indices`, valid only during this call.
  static void Imported(void* context, int added, int duplicate, int rejected, const int* conflict_indices, int conflict_count) {
    auto* batch = static_cast<PasswordBatch*>(context);
    batch->Reply(added, duplicate, conflict_count, rejected, conflict_indices, conflict_count);
    batch->Release();
  }

  static void Replaced(void* context, int updated, int missing, int rejected) {
    auto* batch = static_cast<PasswordBatch*>(context);
    batch->ReplyReplaced(updated, missing, rejected);
    batch->Release();
  }

 private:
  const SecretField& Keep(const char* bytes, size_t length) {
    fields_.push_back(std::make_unique<SecretField>(bytes, length));
    return *fields_.back();
  }

  void Reply(int added, int duplicate, int conflict, int rejected, const int* indices, int index_count) {
    std::string json = "{\"added\":" + std::to_string(added) + ",\"duplicate\":" + std::to_string(duplicate) +
                       ",\"conflict\":" + std::to_string(conflict) + ",\"rejected\":" + std::to_string(rejected);
    if (indices) {
      json += ",\"conflicts\":[";
      bool first = true;
      // SAFETY: the fork's import callback (Imported) hands `index_count`
      // indices at `indices`, alive during the call.
      for (const int index : UNSAFE_BUFFERS(SpanFromCArray(indices, index_count))) {
        json += (first ? "" : ",") + std::to_string(index);
        first = false;
      }
      json += "]";
    }
    Emit(CMUX_SHIM_REPLY, 0, reply_, added, 0, json + "}");
  }

  void ReplyReplaced(int updated, int missing, int rejected) {
    Emit(CMUX_SHIM_REPLY, 0, reply_, updated, 0,
         "{\"updated\":" + std::to_string(updated) + ",\"missing\":" + std::to_string(missing) +
             ",\"rejected\":" + std::to_string(rejected) + "}");
  }

  Mode mode_;
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

int StartBatch(PasswordBatch::Mode mode, const char* profile_cache_path, int reply,
               const cmux_shim_password_entry* entries, int count) {
  if (!profile_cache_path || !*profile_cache_path || IsOffTheRecordKey(profile_cache_path) || !entries || count <= 0) {
    return 0;
  }
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  // Copied here, so the caller may zero its buffers as soon as this returns.
  CefRefPtr<PasswordBatch> batch = new PasswordBatch(mode, profile_cache_path, reply, entries, count);
  context->GetCookieManager(new StartWhenReady(batch));
  return 1;
}

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
  if (!fork_api().password_import && !fork_api().password_import_v2) return 0;
  return StartBatch(PasswordBatch::Mode::kImport, profile_cache_path, reply, entries, count);
}

int cmux_shim_password_replace_available(void) {
  return fork_api().password_import_v2 && fork_api().password_import_replace ? 1 : 0;
}

int cmux_shim_replace_passwords(const char* profile_cache_path, int reply, const cmux_shim_password_entry* entries, int count) {
  if (!fork_api().password_import_replace) return 0;
  return StartBatch(PasswordBatch::Mode::kReplace, profile_cache_path, reply, entries, count);
}

int cmux_shim_set_password_fill(int browser_id, int enabled) {
  return fork_api().tab_set_password_fill ? fork_api().tab_set_password_fill(browser_id, enabled ? 1 : 0) : 0;
}

}  // extern "C"

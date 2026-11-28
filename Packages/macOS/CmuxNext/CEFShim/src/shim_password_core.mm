// Password manager core for the Passwords page (plans/cmux-next/passwords.md
// 1.4): the fork's cmux_password_list, _remove, _exception_remove,
// _set_username, _reveal and _export (API 18). Lists carry metadata only.
// A revealed password never travels in a REPLY: password_reveal_relay.h
// hands it to the app's callback and zeroes the shim's copy. Nothing here
// logs a value.

#include <string>
#include <vector>

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "password_reveal_relay.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

enum class CoreOp { kList, kRemove, kExceptionRemove, kSetUsername, kReveal, kExport };

// One request, kept alive until the fork replies.
class PasswordCoreRequest : public CefBaseRefCounted {
 public:
  PasswordCoreRequest(CoreOp op, std::string path, int reply) : op_(op), path_(std::move(path)), reply_(reply) {}

  std::vector<std::string> ids;
  std::string username;
  std::string file_path;
  PasswordRevealFn reveal_done = nullptr;
  void* reveal_ctx = nullptr;

  // Runs once the profile's storage is initialized.
  void Start() {
    AddRef();
    const ForkApi& api = fork_api();
    const char* path = path_.c_str();
    int started = 0;
    switch (op_) {
      case CoreOp::kList:
        started = api.password_list ? api.password_list(path, &Listed, this) : 0;
        break;
      case CoreOp::kRemove: {
        std::vector<const char*> pointers;
        for (const auto& id : ids) pointers.push_back(id.c_str());
        started = api.password_remove
                      ? api.password_remove(path, pointers.data(), static_cast<int>(pointers.size()), &Counted, this)
                      : 0;
        break;
      }
      case CoreOp::kExceptionRemove:
        started = api.password_exception_remove ? api.password_exception_remove(path, ids[0].c_str(), &Counted, this) : 0;
        break;
      case CoreOp::kSetUsername:
        started = api.password_set_username ? api.password_set_username(path, ids[0].c_str(), username.c_str(), &Counted, this)
                                            : 0;
        break;
      case CoreOp::kReveal:
        started = api.password_reveal ? api.password_reveal(path, ids[0].c_str(), &Revealed, this) : 0;
        break;
      case CoreOp::kExport:
        started = api.password_export ? api.password_export(path, file_path.c_str(), &Counted, this) : 0;
        break;
    }
    if (!started) {
      if (op_ == CoreOp::kReveal) {
        RelayRevealedPassword(nullptr, 0, reveal_done, reveal_ctx);
      } else {
        Emit(CMUX_SHIM_REPLY, 0, reply_, op_ == CoreOp::kList ? 0 : -1, 0);
      }
      Release();
    }
  }

  static void Listed(void* context, const char* json) {
    auto* request = static_cast<PasswordCoreRequest*>(context);
    Emit(CMUX_SHIM_REPLY, 0, request->reply_, json ? 1 : 0, 0, json ? std::string(json) : std::string());
    request->Release();
  }

  static void Counted(void* context, int result) {
    auto* request = static_cast<PasswordCoreRequest*>(context);
    Emit(CMUX_SHIM_REPLY, 0, request->reply_, result, 0);
    request->Release();
  }

  static void Revealed(void* context, const char* password, size_t length) {
    auto* request = static_cast<PasswordCoreRequest*>(context);
    RelayRevealedPassword(password, length, request->reveal_done, request->reveal_ctx);
    request->Release();
  }

 private:
  CoreOp op_;
  std::string path_;
  int reply_;
  IMPLEMENT_REFCOUNTING(PasswordCoreRequest);
};

// The cookie manager's ready callback: the profile behind the context is initialized.
class StartCoreWhenReady : public CefCompletionCallback {
 public:
  explicit StartCoreWhenReady(CefRefPtr<PasswordCoreRequest> request) : request_(request) {}
  void OnComplete() override { request_->Start(); }

 private:
  CefRefPtr<PasswordCoreRequest> request_;
  IMPLEMENT_REFCOUNTING(StartCoreWhenReady);
};

int StartCore(const char* profile_cache_path, CefRefPtr<PasswordCoreRequest> request) {
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  context->GetCookieManager(new StartCoreWhenReady(request));
  return 1;
}

bool UsablePath(const char* profile_cache_path) {
  return profile_cache_path && *profile_cache_path && !IsOffTheRecordKey(profile_cache_path);
}

bool UsableId(const char* id) {
  return id && *id;
}

}  // namespace

extern "C" {

int cmux_shim_password_core_available(void) {
  const ForkApi& api = fork_api();
  return api.password_list && api.password_remove && api.password_exception_remove && api.password_set_username &&
                 api.password_reveal && api.password_export
             ? 1
             : 0;
}

int cmux_shim_password_list(const char* profile_cache_path, int reply) {
  if (!fork_api().password_list || !UsablePath(profile_cache_path)) return 0;
  return StartCore(profile_cache_path, new PasswordCoreRequest(CoreOp::kList, profile_cache_path, reply));
}

int cmux_shim_password_remove(const char* profile_cache_path, const char* const* ids, int count, int reply) {
  if (!fork_api().password_remove || !UsablePath(profile_cache_path) || !ids || count <= 0) return 0;
  CefRefPtr<PasswordCoreRequest> request = new PasswordCoreRequest(CoreOp::kRemove, profile_cache_path, reply);
  for (int i = 0; i < count; ++i) {
    if (!UsableId(ids[i])) return 0;
    request->ids.emplace_back(ids[i]);
  }
  return StartCore(profile_cache_path, request);
}

int cmux_shim_password_exception_remove(const char* profile_cache_path, const char* id, int reply) {
  if (!fork_api().password_exception_remove || !UsablePath(profile_cache_path) || !UsableId(id)) return 0;
  CefRefPtr<PasswordCoreRequest> request = new PasswordCoreRequest(CoreOp::kExceptionRemove, profile_cache_path, reply);
  request->ids.emplace_back(id);
  return StartCore(profile_cache_path, request);
}

int cmux_shim_password_set_username(const char* profile_cache_path, const char* id, const char* username, int reply) {
  if (!fork_api().password_set_username || !UsablePath(profile_cache_path) || !UsableId(id) || !username) return 0;
  CefRefPtr<PasswordCoreRequest> request = new PasswordCoreRequest(CoreOp::kSetUsername, profile_cache_path, reply);
  request->ids.emplace_back(id);
  request->username = username;
  return StartCore(profile_cache_path, request);
}

int cmux_shim_password_reveal(const char* profile_cache_path, const char* id, cmux_shim_password_reveal_fn done, void* ctx) {
  if (!fork_api().password_reveal || !UsablePath(profile_cache_path) || !UsableId(id) || !done) return 0;
  CefRefPtr<PasswordCoreRequest> request = new PasswordCoreRequest(CoreOp::kReveal, profile_cache_path, 0);
  request->ids.emplace_back(id);
  request->reveal_done = done;
  request->reveal_ctx = ctx;
  return StartCore(profile_cache_path, request);
}

int cmux_shim_password_export(const char* profile_cache_path, const char* file_path, int reply) {
  if (!fork_api().password_export || !UsablePath(profile_cache_path) || !file_path || file_path[0] != '/') return 0;
  CefRefPtr<PasswordCoreRequest> request = new PasswordCoreRequest(CoreOp::kExport, profile_cache_path, reply);
  request->file_path = file_path;
  return StartCore(profile_cache_path, request);
}

}  // extern "C"

// Clear Browsing Data (cx-d0d.23): deletes the cookies of a cmux profile's
// request context created at or after a time, also for a profile no tab has
// opened yet. Replies once with the number deleted.

#include <cstdint>

#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// Deletes each visited cookie created at or after `since_`; CEF releases the
// visitor on the UI thread after the last cookie (or at once for none),
// which replies.
class ClearSince : public CefCookieVisitor {
 public:
  ClearSince(int64_t since, int reply) : since_(since), reply_(reply) {}
  ~ClearSince() override { Emit(CMUX_SHIM_REPLY, 0, reply_, deleted_, 0, "[]"); }

  bool Visit(const CefCookie& cookie, int count, int total, bool& delete_cookie) override {
    delete_cookie = cookie.creation.val >= since_;
    if (delete_cookie) ++deleted_;
    return true;
  }

 private:
  int64_t since_;
  int reply_;
  int deleted_ = 0;
  IMPLEMENT_REFCOUNTING(ClearSince);
};

// Runs once the context's cookie storage is initialized.
class ClearWhenReady : public CefCompletionCallback {
 public:
  ClearWhenReady(CefRefPtr<CefRequestContext> context, int64_t since, int reply)
      : context_(context), since_(since), reply_(reply) {}

  void OnComplete() override {
    CefRefPtr<CefCookieManager> manager = context_->GetCookieManager(nullptr);
    CefRefPtr<ClearSince> visitor = new ClearSince(since_, reply_);
    // A manager that cannot visit still replies (0) when `visitor` goes.
    if (manager) manager->VisitAllCookies(visitor);
  }

 private:
  CefRefPtr<CefRequestContext> context_;
  int64_t since_;
  int reply_;
  IMPLEMENT_REFCOUNTING(ClearWhenReady);
};

}  // namespace

extern "C" {

int cmux_shim_clear_cookies(const char* profile_cache_path, int reply, int64_t since) {
  if (!profile_cache_path || !*profile_cache_path || IsOffTheRecordKey(profile_cache_path)) return 0;
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  context->GetCookieManager(new ClearWhenReady(context, since, reply));
  return 1;
}

}  // extern "C"

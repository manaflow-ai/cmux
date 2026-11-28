// Browser import (plans/cmux-next/browser.md, "Cookie import"): writes the
// cookies of one source browser profile into the CefCookieManager of a cmux
// profile's request context. The cookie values pass through memory only;
// nothing here logs them. Replies once with the number written and the
// number the cookie store rejected.

#include <atomic>
#include <cstdlib>

#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

// Counts SetCookie results; replies when the last callback ran (CEF calls
// every callback on the UI thread).
class CookieTally : public CefBaseRefCounted {
 public:
  CookieTally(int reply, int expected) : reply_(reply), remaining_(expected) {}
  void Done(bool ok) {
    if (ok) {
      ++written_;
    } else {
      ++rejected_;
    }
    if (--remaining_ == 0) Finish();
  }
  void Finish() {
    if (finished_) return;
    finished_ = true;
    Emit(CMUX_SHIM_REPLY, 0, reply_, written_, 0,
         "{\"written\":" + std::to_string(written_) + ",\"rejected\":" + std::to_string(rejected_) + "}");
  }

 private:
  int reply_;
  int remaining_;
  int written_ = 0;
  int rejected_ = 0;
  bool finished_ = false;
  IMPLEMENT_REFCOUNTING(CookieTally);
};

class SetReply : public CefSetCookieCallback {
 public:
  explicit SetReply(CefRefPtr<CookieTally> tally) : tally_(tally) {}
  void OnComplete(bool success) override { tally_->Done(success); }

 private:
  CefRefPtr<CookieTally> tally_;
  IMPLEMENT_REFCOUNTING(SetReply);
};

int64_t Microseconds(CefRefPtr<CefDictionaryValue> entry, const char* key) {
  // Sent as strings: Chromium microseconds since 1601 exceed a double's 53 bits.
  if (!entry->HasKey(key)) return 0;
  return std::strtoll(entry->GetString(key).ToString().c_str(), nullptr, 10);
}

// Runs once the context's cookie storage is initialized.
class WriteWhenReady : public CefCompletionCallback {
 public:
  WriteWhenReady(CefRefPtr<CefRequestContext> context, CefRefPtr<CefListValue> list, int reply)
      : context_(context), list_(list), reply_(reply) {}

  void OnComplete() override {
    CefRefPtr<CefCookieManager> manager = context_->GetCookieManager(nullptr);
    const int count = static_cast<int>(list_->GetSize());
    CefRefPtr<CookieTally> tally = new CookieTally(reply_, count);
    if (!manager || count == 0) {
      for (int i = 0; manager == nullptr && i < count; ++i) tally->Done(false);
      tally->Finish();
      return;
    }
    for (int i = 0; i < count; ++i) {
      CefRefPtr<CefDictionaryValue> entry = list_->GetDictionary(i);
      if (!entry) {
        tally->Done(false);
        continue;
      }
      CefCookie cookie;
      CefString(&cookie.name) = entry->GetString("name");
      CefString(&cookie.value) = entry->GetString("value");
      CefString(&cookie.domain) = entry->GetString("domain");
      CefString(&cookie.path) = entry->GetString("path");
      cookie.secure = entry->GetBool("secure");
      cookie.httponly = entry->GetBool("httponly");
      cookie.same_site = static_cast<cef_cookie_same_site_t>(entry->GetInt("same_site"));
      cookie.creation.val = Microseconds(entry, "creation");
      cookie.last_access.val = Microseconds(entry, "last_access");
      cookie.has_expires = entry->GetBool("has_expires");
      cookie.expires.val = Microseconds(entry, "expires");
      // SetCookie returns false (and never calls back) for an invalid URL.
      if (!manager->SetCookie(entry->GetString("url"), cookie, new SetReply(tally))) tally->Done(false);
    }
  }

 private:
  CefRefPtr<CefRequestContext> context_;
  CefRefPtr<CefListValue> list_;
  int reply_;
  IMPLEMENT_REFCOUNTING(WriteWhenReady);
};

}  // namespace

extern "C" {

int cmux_shim_import_cookies(const char* profile_cache_path, int reply, const char* json) {
  if (!profile_cache_path || !*profile_cache_path || IsOffTheRecordKey(profile_cache_path) || !json) return 0;
  CefRefPtr<CefValue> parsed = CefParseJSON(json, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_LIST) return 0;
  CefRefPtr<CefRequestContext> context = RequestContextFor(profile_cache_path);
  if (!context) return 0;
  // The callback runs after the profile's cookie store has loaded, also for
  // a profile no tab has opened yet in this launch.
  context->GetCookieManager(new WriteWhenReady(context, parsed->GetList(), reply));
  return 1;
}

}  // extern "C"

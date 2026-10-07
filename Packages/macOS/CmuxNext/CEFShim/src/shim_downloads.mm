// Downloads: Chromium never shows its own download UI or save dialog. Every
// download asks the host for its path (DOWNLOAD_STARTED, answered with
// cmux_shim_download_continue) and reports progress and its end as events.
// The host owns the policy (where files go, quarantine); this file only
// moves CEF callbacks to events and back.
//
// Chromium counts download ids per request context (profile), so every
// event and host call uses a shim token instead (DownloadTable in
// download_state.h): one per OnBeforeDownload, never reused.

#include "download_state.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

bool SameContext(const CefRefPtr<CefRequestContext>& a, const CefRefPtr<CefRequestContext>& b) {
  if (!a || !b) return a.get() == b.get();
  return a->IsSame(b);
}

using Table = DownloadTable<CefRefPtr<CefRequestContext>, CefRefPtr<CefBeforeDownloadCallback>,
                            CefRefPtr<CefDownloadItemCallback>>;

// UI thread. Never destroyed at exit (its callbacks would outlive
// CefShutdown); ForgetDownloads empties it before shutdown.
Table& downloads() {
  static Table* table = new Table(SameContext);
  return *table;
}

CefRefPtr<CefRequestContext> ContextOf(CefRefPtr<CefBrowser> browser) {
  return browser ? browser->GetHost()->GetRequestContext() : nullptr;
}

class Handler : public CefDownloadHandler {
 public:
  // The host decides the path; Chromium's dialog never shows.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    const int token = downloads().Begin(ContextOf(browser), item->GetId(), callback);
    Emit(CMUX_SHIM_DOWNLOAD_STARTED, browser ? browser->GetIdentifier() : 0, token, item->GetTotalBytes(), 0,
         item->GetOriginalUrl().ToString(), suggested_name.ToString());
    // A callback the host never answers cancels the download when it is
    // released (cmux_shim_download_continue with no path).
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    // Updates before OnBeforeDownload, and after the end, have no token.
    const int token = downloads().TokenOf(ContextOf(browser), item->GetId());
    if (!token) return;
    const int browser_id = browser ? browser->GetIdentifier() : 0;
    int state = 0;
    if (item->IsComplete()) state = 1;
    else if (item->IsCanceled()) state = 2;
    else if (item->IsInterrupted()) state = 3;
    if (state == 0) {
      // A cancel the host sent before this first callback applies now.
      if (downloads().Running(token, callback)) callback->Cancel();
      Emit(CMUX_SHIM_DOWNLOAD_PROGRESS, browser_id, token, item->GetReceivedBytes(), item->GetTotalBytes(),
           std::to_string(item->GetCurrentSpeed()), item->IsPaused() ? "paused" : "");
      return;
    }
    downloads().Finish(token);
    Emit(CMUX_SHIM_DOWNLOAD_DONE, browser_id, token, state, item->GetInterruptReason(), item->GetFullPath().ToString());
  }

 private:
  IMPLEMENT_REFCOUNTING(Handler);
};

}  // namespace

CefRefPtr<CefDownloadHandler> DownloadHandler() {
  static CefRefPtr<CefDownloadHandler> handler = new Handler();
  return handler;
}

void ForgetDownloads() {
  downloads().Clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_download_url(int browser_id, const char* url) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser || !url || !IsDownloadableUrl(url)) return 0;
  browser->GetHost()->StartDownload(url);
  return 1;
}

int cmux_shim_download_continue(int download_id, const char* path) {
  CefRefPtr<CefBeforeDownloadCallback> callback;
  if (!downloads().TakeBefore(download_id, &callback)) return 0;
  if (path && *path) {
    callback->Continue(path, false);
  } else {
    // Releasing the callback without Continue cancels the download; the
    // host already forgot it.
    downloads().Finish(download_id);
  }
  return 1;
}

int cmux_shim_download_control(int download_id, int command) {
  CefRefPtr<CefDownloadItemCallback> callback;
  switch (downloads().Command(download_id, command, &callback)) {
    case Table::Control::kUnknown:
      return 0;
    case Table::Control::kHeld:
      return 1;
    case Table::Control::kApply:
      break;
  }
  switch (command) {
    case 0: callback->Cancel(); break;
    case 1: callback->Pause(); break;
    case 2: callback->Resume(); break;
    default: return 0;
  }
  return 1;
}

}  // extern "C"

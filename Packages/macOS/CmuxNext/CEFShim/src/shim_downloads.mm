// Downloads: Chromium never shows its own download UI or save dialog. Every
// download asks the host for its path (DOWNLOAD_STARTED, answered with
// cmux_shim_download_continue) and reports progress and its end as events.
// The host owns the policy (where files go, quarantine); this file only
// moves CEF callbacks to events and back.

#include <set>

#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Downloads waiting for the host's path, by download id (UI thread).
std::map<uint32_t, CefRefPtr<CefBeforeDownloadCallback>>& waiting() {
  static std::map<uint32_t, CefRefPtr<CefBeforeDownloadCallback>> map;
  return map;
}

// The latest cancel/pause/resume callback of each running download.
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>>& running() {
  static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> map;
  return map;
}

// Downloads that already sent DOWNLOAD_DONE.
std::set<uint32_t>& finished() {
  static std::set<uint32_t> set;
  return set;
}

class Handler : public CefDownloadHandler {
 public:
  // The host decides the path; Chromium's dialog never shows.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    const uint32_t id = item->GetId();
    waiting()[id] = callback;
    Emit(CMUX_SHIM_DOWNLOAD_STARTED, browser ? browser->GetIdentifier() : 0, static_cast<int>(id), item->GetTotalBytes(),
         0, item->GetOriginalUrl().ToString(), suggested_name.ToString());
    // A callback the host never answers cancels the download when it is
    // released (cmux_shim_download_continue with no path).
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    const uint32_t id = item->GetId();
    if (finished().count(id)) return;
    const int browser_id = browser ? browser->GetIdentifier() : 0;
    int state = 0;
    if (item->IsComplete()) state = 1;
    else if (item->IsCanceled()) state = 2;
    else if (item->IsInterrupted()) state = 3;
    if (state == 0) {
      running()[id] = callback;
      Emit(CMUX_SHIM_DOWNLOAD_PROGRESS, browser_id, static_cast<int>(id), item->GetReceivedBytes(), item->GetTotalBytes(),
           std::to_string(item->GetCurrentSpeed()), item->IsPaused() ? "paused" : "");
      return;
    }
    finished().insert(id);
    running().erase(id);
    waiting().erase(id);
    Emit(CMUX_SHIM_DOWNLOAD_DONE, browser_id, static_cast<int>(id), state, item->GetInterruptReason(),
         item->GetFullPath().ToString());
  }

 private:
  IMPLEMENT_REFCOUNTING(Handler);
};

}  // namespace

CefRefPtr<CefDownloadHandler> DownloadHandler() {
  static CefRefPtr<CefDownloadHandler> handler = new Handler();
  return handler;
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_download_url(int browser_id, const char* url) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser || !url || !*url) return 0;
  browser->GetHost()->StartDownload(url);
  return 1;
}

int cmux_shim_download_continue(int download_id, const char* path) {
  auto it = waiting().find(static_cast<uint32_t>(download_id));
  if (it == waiting().end()) return 0;
  CefRefPtr<CefBeforeDownloadCallback> callback = it->second;
  waiting().erase(it);
  // Releasing the callback without Continue cancels the download.
  if (path && *path) callback->Continue(path, false);
  return 1;
}

int cmux_shim_download_control(int download_id, int command) {
  auto it = running().find(static_cast<uint32_t>(download_id));
  if (it == running().end()) return 0;
  switch (command) {
    case 0: it->second->Cancel(); break;
    case 1: it->second->Pause(); break;
    case 2: it->second->Resume(); break;
    default: return 0;
  }
  return 1;
}

}  // extern "C"

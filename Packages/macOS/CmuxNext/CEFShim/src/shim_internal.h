// Internal state shared by the shim translation units.
#pragma once

#include <map>
#include <vector>
#include <string>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_request_context.h"
#include "../include/cmux_cef_shim.h"

namespace cmux_shim {

// Fork C API resolved with dlsym (include/cef_cmux.h in the artifact).
struct ForkApi {
  int version = 0;
  void (*free_string)(char*) = nullptr;
  void (*set_observer)(void (*)(void*, int, int, int, int), void*) = nullptr;
  int (*tab_add)(int, const char*, int, int) = nullptr;
  int (*tab_activate)(int) = nullptr;
  int (*tab_window_id)(int) = nullptr;
  char* (*ext_actions)(int, int) = nullptr;
  int (*ext_action_run)(int, const char*, int, int) = nullptr;
  void (*ext_action_hide_popup)(int, const char*) = nullptr;
  void (*ext_action_context_menu)(int, const char*, int, int) = nullptr;
  int (*window_count)() = nullptr;
  // API version 3.
  char* (*ext_list)(int) = nullptr;
  int (*ext_set_enabled)(int, const char*, int) = nullptr;
  int (*ext_uninstall)(int, const char*) = nullptr;
  int (*ext_set_pinned)(int, const char*, int) = nullptr;
  int (*ext_open_options)(int, const char*) = nullptr;
  int (*ext_load_unpacked)(int, const char*) = nullptr;
  char* (*ext_commands)(int) = nullptr;
  int (*ext_command_run)(int, const char*, const char*) = nullptr;
  int (*tab_move_to_window)(int, int, int) = nullptr;
};

struct Host {
  void* ctx = nullptr;
  cmux_shim_schedule_fn schedule = nullptr;
  cmux_shim_event_fn event = nullptr;
  cmux_shim_key_fn key = nullptr;
};

ForkApi& fork_api();
void InstallForkObserver();
Host& host();

// Emits one event to Swift (main thread only).
void Emit(int kind,
          int browser_id,
          int request = 0,
          int64_t a = 0,
          int64_t b = 0,
          const std::string& s1 = std::string(),
          const std::string& s2 = std::string());

// Live browsers by identifier (UI thread only).
std::map<int, CefRefPtr<CefBrowser>>& browsers();
CefRefPtr<CefBrowser> BrowserById(int browser_id);

// Browsers the host asked to close (so DoClose can tell window.close apart).
void MarkHostClose(int browser_id);
bool TakeHostClose(int browser_id);

// Request contexts per profile cache path.
CefRefPtr<CefRequestContext> RequestContextFor(const std::string& cache_path);

// One client per Chromium window. The first OnAfterCreated through it reports
// `request`; later tabs of the window (cmux_tab_add, chrome.tabs.create,
// target=_blank) report request 0.
CefRefPtr<CefClient> MakeClient(int request);
// Client for browsers Chromium creates in windows the host did not create
// (CefBrowserProcessHandler::GetDefaultClient).
CefRefPtr<CefClient> DefaultClient();

// Context menus the host is showing, by token (UI thread only).
int StoreMenuCallback(CefRefPtr<CefRunContextMenuCallback> callback);
CefRefPtr<CefRunContextMenuCallback> TakeMenuCallback(int token);
CefRefPtr<CefApp> MakeApp(std::vector<std::string> switches);

}  // namespace cmux_shim

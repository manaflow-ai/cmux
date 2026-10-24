// A page's file chooser (<input type=file>, showSaveFilePicker) goes to the
// host app instead of Chromium's own NSOpenPanel on the main thread, which
// cost 160-830 ms cold per click and blocked about 40 s when the panel
// service hung. The host answers through its one open-panel path
// (WebFileInputAnswering over AppServices.openPanel).

#include "include/cef_dialog_handler.h"
#include "file_dialog_state.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Off until the host answers choosers (cmux_shim_set_file_dialogs): an app
// that does not handle CMUX_SHIM_FILE_DIALOG keeps Chromium's own panel.
bool& enabled() {
  static bool on = false;
  return on;
}

FileDialogs<CefRefPtr<CefFileDialogCallback>>& pending() {
  static FileDialogs<CefRefPtr<CefFileDialogCallback>> dialogs;
  return dialogs;
}

int ModeFor(CefDialogHandler::FileDialogMode mode) {
  switch (mode) {
    case FILE_DIALOG_OPEN_MULTIPLE: return 1;
    case FILE_DIALOG_OPEN_FOLDER: return 2;
    case FILE_DIALOG_SAVE: return 3;
    default: return 0;
  }
}

class FileDialogHandler : public CefDialogHandler {
 public:
  bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                    FileDialogMode mode,
                    const CefString& title,
                    const CefString& default_file_path,
                    const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions,
                    const std::vector<CefString>& accept_descriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    if (!enabled()) return false;
    std::vector<std::string> filters;
    for (const auto& filter : accept_filters) filters.push_back(filter.ToString());
    const int browser_id = browser->GetIdentifier();
    const int dialog_id = pending().Add(browser_id, callback);
    Emit(CMUX_SHIM_FILE_DIALOG, browser_id, dialog_id, ModeFor(mode), 0, JoinFilters(filters),
         default_file_path.ToString());
    return true;  // the host answers; Chromium shows no panel of its own
  }

 private:
  IMPLEMENT_REFCOUNTING(FileDialogHandler);
};

}  // namespace

CefRefPtr<CefDialogHandler> FileDialogHandlerInstance() {
  static CefRefPtr<CefDialogHandler> handler = new FileDialogHandler();
  return handler;
}

void CancelFileDialogs(int browser_id) {
  for (auto& callback : pending().TakeAll(browser_id)) callback->Cancel();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

void cmux_shim_set_file_dialogs(int enabled_by_host) {
  enabled() = enabled_by_host != 0;
}

int cmux_shim_file_dialog_answer(int dialog_id, int multiple, const char* paths) {
  auto callback = pending().Take(dialog_id);
  if (!callback) return 0;
  auto kept = cmux_shim::KeepForMode(cmux_shim::SplitPaths(paths ? paths : ""), multiple != 0);
  if (kept.empty()) {
    (*callback)->Cancel();
    return 1;
  }
  std::vector<CefString> files(kept.begin(), kept.end());
  (*callback)->Continue(files);
  return 1;
}

}  // extern "C"

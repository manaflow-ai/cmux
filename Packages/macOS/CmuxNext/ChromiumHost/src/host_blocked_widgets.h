// No window of the Chromium Host on screen (plans/cmux-next/chrome-parity/
// p01-process.md): the host's half of the fork's
// blocked widgets (task 176, fork API 31).
//
// While the host's handler is set, every Views widget of a detached page (or
// of no page) gets a headless window from the fork and is reported here
// instead of ordering in. 062's permission prompts, 063's JavaScript dialogs
// and HTTP auth, 228's choosers and cmux's find each take their request
// through their own shim event, before Chromium makes a widget; a widget of
// one of those kinds here is a request its cmux UI did not take, and the
// fork gives no way to hand a made widget to a cmux UI. So the host dismisses
// each one as Chrome's Escape does (cmux_blocked_widget_close,
// DialogClientView::AcceleratorPressed in ui/views/window/dialog_client_view.cc),
// a cancel of which Chromium keeps no decision, and logs it as
// BLOCKED_WIDGET lines. A page never waits on a dialog no one can see. The
// find bar is dismissed too, as the shim's blocked window commands are
// (CEFRuntime+Windows.swift): cmux's bindings decide what a key in a page
// does, so a find Chromium started by itself does not open cmux's, and
// closing it ends a find session with nothing kept.
//
// A permission prompt is the exception: Escape on it is the person's
// dismissal (PermissionPromptBubbleBaseView's close callback,
// PermissionRequestManager::Dismiss), which PermissionDecisionAutoBlocker
// counts toward the origin's embargo
// (components/permissions/permission_decision_auto_blocker.cc). The host
// holds it unanswered, as Chrome leaves a prompt the person has not looked
// at, logs it as held, and Chromium ends it with the page's navigation or
// close. A held prompt fails its bench row: 062 did not take the request.
// The line's owner= names the cmux UI of the widget's kind.
//
// The window observer in browser_host_main.mm is the backstop for what the
// fork cannot block (a window-modal sheet, an AppKit panel such as
// NSColorPanel): it orders the window out and logs UNEXPECTED_WINDOW with the
// window's class and a hash of its title (never the title: it can be page
// text).
//
// The lines go to the host's stderr, which is cmux's app log;
// chromium-host-bench.py --native-ui counts them per row
// (chromium_host_windows.py parses this format).
//
// Fork API 31, include/cef_cmux.h:
//   typedef void (*cmux_blocked_widget_fn)(void* context, int browser_id,
//       int widget_id, int kind, int visible, const char* view_class,
//       int x, int y, int width, int height);
//   int cmux_set_blocked_widget_handler(cmux_blocked_widget_fn fn, void* context);
//   int cmux_blocked_widget_close(int widget_id);
// UI thread only; `visible` 1 when the widget shows (and again when it moves
// or resizes), 0 when it hides or closes (its id is then gone). The close
// returns 1 for a blocked widget it cancelled, and the handler then reports
// the widget hidden, unless the dialog refuses to cancel: then it stays. It
// returns 0 for a widget it does not know, or a hosted one.
//
// No CEF, no AppKit: scripts/cmux-next/tests/chromium-host-blocked-widgets.test.sh
// compiles it on Linux. UI thread only: no lock.
#pragma once

#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>

namespace cmux_host {

// The fork's cmux_blocked_widget_fn, cmux_set_blocked_widget_handler and
// cmux_blocked_widget_close.
using BlockedWidgetFn = void (*)(void* context, int browser_id, int widget_id, int kind, int visible,
                                 const char* view_class, int x, int y, int width, int height);
using SetBlockedWidgetHandlerFn = int (*)(BlockedWidgetFn fn, void* context);
using BlockedWidgetCloseFn = int (*)(int widget_id);

// The cmux UI that answers a kind of request Chromium would show as a widget
// (the log's owner=: the UI that missed the request, not one that took it).
enum class WidgetOwner {
  kNone,
  kPermissionPrompt,  // 062: PERMISSION_PROMPT
  kJavaScriptDialog,  // 063: JS dialogs and HTTP auth
  kChooser,           // 228: device, screen share and external protocol choosers
  kFind,              // cmux's find pill
};

inline const char* OwnerName(WidgetOwner owner) {
  switch (owner) {
    case WidgetOwner::kPermissionPrompt:
      return "permission-prompt";
    case WidgetOwner::kJavaScriptDialog:
      return "js-dialog";
    case WidgetOwner::kChooser:
      return "chooser";
    case WidgetOwner::kFind:
      return "find";
    case WidgetOwner::kNone:
      break;
  }
  return "none";
}

// The owner of a widget by the Views class of the view its delegate shows
// (the fork's view_class; Chromium 154's class names).
inline WidgetOwner OwnerOf(std::string_view view_class) {
  auto starts = [view_class](std::string_view prefix) { return view_class.substr(0, prefix.size()) == prefix; };
  // chrome/browser/ui/views/permissions/: PermissionPromptBubbleBaseView and
  // its one- and two-origin views, EmbeddedPermissionPrompt*View.
  if (starts("PermissionPrompt") || starts("EmbeddedPermissionPrompt")) return WidgetOwner::kPermissionPrompt;
  // chrome/browser/ui/views/javascript_tab_modal_dialog_view_views.h,
  // components/javascript_dialogs/views/app_modal_dialog_view_views.h and
  // the HTTP auth prompt (chrome/browser/ui/views/login_view.h).
  if (view_class == "JavaScriptTabModalDialogViewViews" || view_class == "AppModalDialogViewViews" ||
      view_class == "LoginView") {
    return WidgetOwner::kJavaScriptDialog;
  }
  // chrome/browser/ui/views/device_chooser_content_view.h (Bluetooth, USB,
  // HID, Serial, in ChooserBubbleUiViewDelegate),
  // media_picker/desktop_media_picker_views.h and
  // external_protocol_dialog.h.
  if (view_class == "ChooserBubbleUiViewDelegate" || view_class == "DeviceChooserContentView" ||
      view_class == "DesktopMediaPickerDialogView" || view_class == "ExternalProtocolDialog") {
    return WidgetOwner::kChooser;
  }
  // chrome/browser/ui/views/find_bar_view.h.
  if (view_class == "FindBarView") return WidgetOwner::kFind;
  return WidgetOwner::kNone;
}

// One report of the fork's handler.
struct BlockedWidget {
  int browser_id = 0;  // Chromium's id of the page, 0 for no page
  int widget_id = 0;
  int kind = 0;  // a CMUX_RP_SURFACE_* kind, 0 for any other widget
  bool visible = false;
  std::string view_class;  // "" for a page popup
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

// What the host did with a shown blocked widget.
enum class BlockedAction {
  kDismissed,    // the close cancelled it and the fork reported it hidden
  kRefused,      // the close returned 1 and it still shows: it does not cancel on Escape
  kCloseFailed,  // the close returned 0: the fork does not know the widget it reported
  kGone,         // it hid or closed before the dismissal ran (or, held, before anyone answered it)
  kHeld,         // a permission prompt, never closed: its Escape would record a dismissal
};

// Whether the host may dismiss the widget with Escape: false when Chromium
// records that Escape as the person's decision (a permission prompt).
inline bool DismissesWithEscape(std::string_view view_class) {
  return OwnerOf(view_class) != WidgetOwner::kPermissionPrompt;
}

inline const char* ActionName(BlockedAction action) {
  switch (action) {
    case BlockedAction::kDismissed:
      return "dismissed";
    case BlockedAction::kRefused:
      return "refused";
    case BlockedAction::kCloseFailed:
      return "close-failed";
    case BlockedAction::kHeld:
      return "held";
    case BlockedAction::kGone:
      break;
  }
  return "gone";
}

// A class name as one token of a log line: anything but [A-Za-z0-9_.:] is
// '_' (Views and Objective-C class names have none of those), and no name
// (a page popup) is "-".
inline std::string LogToken(std::string_view text) {
  if (text.empty()) return "-";
  std::string token(text.substr(0, 128));
  for (char& c : token) {
    const bool keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                      c == '.' || c == ':';
    if (!keep) c = '_';
  }
  return token;
}

// The line for a widget the host handled (no prefix; the caller adds
// "cmux-chromium-host: ").
inline std::string BlockedWidgetLine(const BlockedWidget& widget, BlockedAction action) {
  char rect[64];
  std::snprintf(rect, sizeof rect, "%d,%d,%d,%d", widget.x, widget.y, widget.width, widget.height);
  return "BLOCKED_WIDGET browser=" + std::to_string(widget.browser_id) + " widget=" + std::to_string(widget.widget_id) +
         " kind=" + std::to_string(widget.kind) + " class=" + LogToken(widget.view_class) + " rect=" + rect +
         " visible=" + (widget.visible ? "1" : "0") + " owner=" + OwnerName(OwnerOf(widget.view_class)) +
         " action=" + ActionName(action);
}

// FNV-1a 32 of the title's bytes: one window's title is recognizable across
// lines with none of its text in the log.
inline uint32_t TitleHash(std::string_view title) {
  uint32_t hash = 2166136261u;
  for (unsigned char c : title) {
    hash ^= c;
    hash *= 16777619u;
  }
  return hash;
}

// The backstop's line for a host window it found on screen. `sheet`: it
// ended the window's sheet instead of ordering it out.
inline std::string UnexpectedWindowLine(std::string_view window_class, std::string_view title, bool sheet) {
  char hash[16];
  std::snprintf(hash, sizeof hash, "%08x", TitleHash(title));
  return "UNEXPECTED_WINDOW class=" + LogToken(window_class) + " title=" + hash +
         " action=" + (sheet ? "sheet-ended" : "ordered-out");
}

// The host's blocked widget handler: each widget that shows is dismissed
// once, in a UI task after the report (outside the widget's own Show, as
// Chrome's Escape arrives as an event of its own). It is logged as dismissed
// only when the fork reports it hidden; one that still shows after the close
// is logged as refused and kept, so its later move reports neither dismiss
// nor log it again, and its hide, if it comes, logs it as dismissed. A
// permission prompt is never closed: it is logged as held when it shows and
// as gone when Chromium ends it. UI thread only.
class BlockedWidgets {
 public:
  using Close = std::function<int(int widget_id)>;
  using Post = std::function<void(std::function<void()>)>;
  using Log = std::function<void(const std::string& line)>;

  // `close` is the fork's cmux_blocked_widget_close, `post` runs a task
  // later on the UI thread, `log` writes one line.
  BlockedWidgets(Close close, Post post, Log log)
      : close_(std::move(close)), post_(std::move(post)), log_(std::move(log)) {}
  BlockedWidgets(const BlockedWidgets&) = delete;
  BlockedWidgets& operator=(const BlockedWidgets&) = delete;

  // Installs OnBlockedWidget through the fork's setter; false when the fork
  // has none or refused it (a remote presentation process).
  bool Install(SetBlockedWidgetHandlerFn set) { return set && set(&BlockedWidgets::OnBlockedWidget, this) == 1; }

  // The fork's cmux_blocked_widget_fn; `context` is this.
  static void OnBlockedWidget(void* context, int browser_id, int widget_id, int kind, int visible,
                              const char* view_class, int x, int y, int width, int height) {
    BlockedWidget widget{browser_id, widget_id, kind, visible != 0, view_class ? view_class : "", x, y, width, height};
    static_cast<BlockedWidgets*>(context)->Report(std::move(widget));
  }

  void Report(BlockedWidget widget) {
    const int id = widget.widget_id;
    auto found = widgets_.find(id);
    if (!widget.visible) {
      if (found == widgets_.end()) return;
      const Entry entry = std::move(found->second);
      widgets_.erase(found);
      switch (entry.state) {
        case State::kPending:  // hid before its dismissal ran (the page navigated, Chromium closed it)
          log_(BlockedWidgetLine(entry.widget, BlockedAction::kGone));
          break;
        case State::kRefused:  // went at last after a refused close
          log_(BlockedWidgetLine(entry.widget, BlockedAction::kDismissed));
          break;
        case State::kHeld:  // Chromium ended the prompt (the page navigated or closed)
          log_(BlockedWidgetLine(entry.widget, BlockedAction::kGone));
          break;
        case State::kClosing:      // the close's own hide: Dismiss logs it
        case State::kCloseFailed:  // logged when its close failed
          break;
      }
      return;
    }
    // A move or resize of a widget already reported reports it again.
    if (found != widgets_.end()) return;
    if (!DismissesWithEscape(widget.view_class)) {
      log_(BlockedWidgetLine(widget, BlockedAction::kHeld));
      widgets_.emplace(id, Entry{std::move(widget), State::kHeld});
      return;
    }
    widgets_.emplace(id, Entry{std::move(widget), State::kPending});
    post_([this, id] { Dismiss(id); });
  }

  // Widgets still shown: their dismissal has not run yet, did not take
  // them, or they are held.
  size_t shown() const { return widgets_.size(); }

 private:
  enum class State {
    kPending,      // reported, its dismissal not run yet
    kClosing,      // inside its close
    kRefused,      // its close returned 1 and it still shows
    kCloseFailed,  // its close returned 0
    kHeld,         // a permission prompt, left to Chromium
  };
  struct Entry {
    BlockedWidget widget;
    State state;
  };

  void Dismiss(int id) {
    auto found = widgets_.find(id);
    if (found == widgets_.end()) return;  // hid first, and logged as gone
    found->second.state = State::kClosing;
    const BlockedWidget widget = found->second.widget;
    const int closed = close_(id);
    // The fork reports a cancelled widget hidden before the close returns:
    // Report erased it then.
    found = widgets_.find(id);
    if (found == widgets_.end()) {
      log_(BlockedWidgetLine(widget, BlockedAction::kDismissed));
      return;
    }
    found->second.state = closed == 1 ? State::kRefused : State::kCloseFailed;
    log_(BlockedWidgetLine(widget, closed == 1 ? BlockedAction::kRefused : BlockedAction::kCloseFailed));
  }

  Close close_;
  Post post_;
  Log log_;
  std::unordered_map<int, Entry> widgets_;
};

}  // namespace cmux_host

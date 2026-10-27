// The shim's types and argument conversions for fork API 31 (task 227), with
// no CEF (scripts/cmux-next/test-shim-embedder-ui-args-cpp.sh compiles it
// alone). The shim's exports keep the wire's shapes (one callback per
// handler, int64 records, strings with lengths, a tab's browser id apart
// from a display or window id); the fork's calls take handler structs, int
// indices, NUL-terminated strings and one id. The Fork* structs copy
// include/cef_cmux.h of manaflow-ai/cef cp/p01-process-227 (the artifact's
// header is older than API 31).
#pragma once

#include <climits>
#include <cstdint>
#include <string>
#include <vector>

#include "cmux_cef_shim.h"  // Sources/CmuxNextBrowser/CEF/Shim

namespace cmux_shim {

// cef_cmux.h's cmux_restore_entry_t: NUL-terminated UTF-8, page_state NULL
// for none.
struct ForkRestoreEntry {
  const char* url;
  const char* title;
  const char* page_state;
};

// cef_cmux.h's CMUX_DESKTOP_MEDIA_TAB.
inline constexpr int kDesktopMediaTab = 1 << 2;

// The leading fields of cef_cmux.h's cmux_color_chooser_t; the device chooser
// state and the desktop media request start with the same size and token.
struct ForkColorChooserHead {
  int size;
  int64_t token;
  uint32_t color;
};
struct ForkTokenHead {
  int size;
  int64_t token;
};

// cef_cmux.h's handler structs (fields are only appended; `size` is ours).
struct ForkColorChooserHandler {
  int size;
  void (*open)(void* context, int browser_id, const ForkColorChooserHead* chooser);
  void (*set_color)(void* context, int64_t token, uint32_t color);
  void (*end)(void* context, int64_t token);
  void* context;
};
struct ForkDeviceChooserHandler {
  int size;
  void (*update)(void* context, int browser_id, const ForkTokenHead* state);
  void (*close)(void* context, int64_t token);
  void* context;
};
struct ForkDesktopMediaHandler {
  int size;
  void (*open)(void* context, int browser_id, const ForkTokenHead* request);
  void (*close)(void* context, int64_t token);
  void* context;
};
struct ForkLockHandler {
  int size;
  void (*pointer_lock_requested)(void* context, int browser_id);
  void (*pointer_unlocked)(void* context, int browser_id);
  void (*keyboard_lock_requested)(void* context, int browser_id, int escape_locked);
  void (*keyboard_unlocked)(void* context, int browser_id);
  void* context;
};

// The app's callback for one fork handler.
template <typename Fn>
struct AppHandler {
  Fn fn = nullptr;
  void* context = nullptr;
};

// Sets the fork's handler (NULL when fn is NULL) and then the app's. A
// replaced or removed handler's open requests end inside the fork's call
// (the fork calls the old handler's end or close, the same trampolines), so
// they reach the app's old fn. Returns the fork's answer, 0 without the call.
template <typename Fn, typename ForkHandler>
int SetAppHandler(int (*fork_set)(const ForkHandler*), const ForkHandler* fork_handler, AppHandler<Fn>& app, Fn fn,
                  void* context) {
  if (!fork_set) return 0;
  const int ok = fork_set(fn ? fork_handler : nullptr);
  if (ok) app = fn ? AppHandler<Fn>{fn, context} : AppHandler<Fn>{};
  return ok;
}

// The rows of a device chooser answer as the fork's int indices. False for a
// negative count, NULL choices with a count, or an index the fork's int
// cannot hold (the fork refuses an index past its rows the same way).
inline bool DeviceChoiceIndices(const cmux_shim_device_choice* choices, int count, std::vector<int>* out) {
  out->clear();
  if (count < 0 || (count > 0 && !choices)) return false;
  out->reserve(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    if (choices[i].index < 0 || choices[i].index > INT_MAX) return false;
    out->push_back(static_cast<int>(choices[i].index));
  }
  return true;
}

// The fork's one id of a screen-share answer: the tab's browser id for a
// tab, else the display or window id.
inline int64_t DesktopMediaAnswerId(int source_type, int64_t native_id, int tab_browser_id) {
  return source_type == kDesktopMediaTab ? tab_browser_id : native_id;
}

// NUL-terminated copies of restore entries, alive as long as this object.
class RestoreEntries {
 public:
  RestoreEntries(const cmux_shim_restore_entry* entries, int count) {
    if (!entries || count <= 0) return;
    // Reserved up front: no string moves, so c_str() stays valid.
    strings_.reserve(static_cast<size_t>(count) * 3);
    fork_.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      const cmux_shim_restore_entry& entry = entries[i];
      const char* url = Copy(entry.url, entry.url_length);
      const char* title = Copy(entry.title, entry.title_length);
      const char* state = Copy(entry.page_state, entry.page_state_length);
      fork_.push_back({url, title, *state ? state : nullptr});
    }
  }
  // fork_ points into strings_.
  RestoreEntries(const RestoreEntries&) = delete;
  RestoreEntries& operator=(const RestoreEntries&) = delete;

  const ForkRestoreEntry* data() const { return fork_.data(); }
  int count() const { return static_cast<int>(fork_.size()); }

 private:
  const char* Copy(const char* bytes, size_t length) {
    return strings_.emplace_back(bytes ? bytes : "", bytes ? length : 0).c_str();
  }

  std::vector<std::string> strings_;
  std::vector<ForkRestoreEntry> fork_;
};

}  // namespace cmux_shim

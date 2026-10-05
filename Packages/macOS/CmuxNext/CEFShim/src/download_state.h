// Download and popup bookkeeping of the shim that needs no CEF
// (scripts/cmux-next/test-shim-downloads-cpp.sh compiles it alone).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace cmux_shim {

// The schemes cmux_shim_download_url accepts: http, https, data and blob.
// Never file: (a page or a caller must not copy local files) or anything
// else.
inline bool IsDownloadableUrl(std::string_view url) { return !url.empty(); }  // red stub

// The running downloads by shim token. Chromium counts download ids per
// request context (profile), so two profiles both have a download 1: the
// shim gives each OnBeforeDownload its own token (1, 2, 3, ... never reused
// in a process) and maps (context, Chromium id) to it. Every event and every
// host call uses the token. A download leaves the table when it ends, so a
// later update of it (or of an id Chromium sent before OnBeforeDownload) is
// ignored.
//
// Context is the request context (compared with `same`), Before the
// OnBeforeDownload callback, Item the latest OnDownloadUpdated callback.
template <typename Context, typename Before, typename Item>
class DownloadTable {
 public:
  using Same = bool (*)(const Context&, const Context&);
  enum class Control { kUnknown, kApply, kHeld };

  explicit DownloadTable(Same same) : same_(same) {}

  // Red stub: the Chromium id is the token, contexts are not compared.
  int Begin(const Context& context, uint32_t id, Before before) {
    Entry entry;
    entry.token = static_cast<int>(id);
    entry.context = context;
    entry.id = id;
    entry.before = before;
    entries_.push_back(entry);
    return entry.token;
  }

  int TokenOf(const Context&, uint32_t id) const {
    for (const Entry& entry : entries_) {
      if (entry.id == id) return entry.token;
    }
    return 0;
  }

  // The answer to DOWNLOAD_STARTED takes the OnBeforeDownload callback
  // (once). False when the token is not waiting.
  bool TakeBefore(int token, Before* out) {
    Entry* entry = Find(token);
    if (!entry || !entry->has_before) return false;
    *out = entry->before;
    entry->before = Before();
    entry->has_before = false;
    return true;
  }

  // A running update: remembers its callback. True when a cancel arrived
  // before this first callback and must be applied now (once).
  bool Running(int token, Item item) {
    Entry* entry = Find(token);
    if (!entry) return false;
    entry->item = item;
    entry->has_item = true;
    const bool cancel = entry->cancel_held;
    entry->cancel_held = false;
    return cancel;
  }

  // A host command (0 cancel, 1 pause, 2 resume). kApply: run it on *out.
  // kHeld: a cancel before the first update, applied by Running.
  // kUnknown: no such running download (or pause/resume before an update).
  Control Command(int token, int command, Item* out) {
    Entry* entry = Find(token);
    if (!entry || command < 0 || command > 2) return Control::kUnknown;
    if (entry->has_item) {
      *out = entry->item;
      return Control::kApply;
    }
    return Control::kUnknown;  // red stub
  }

  // DOWNLOAD_DONE (or a cancel answer): forget the download.
  void Finish(int token) {
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].token == token) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
        return;
      }
    }
  }

  // Before CefShutdown: release every callback.
  void Clear() {}  // red stub
  size_t size() const { return entries_.size(); }

 private:
  struct Entry {
    int token = 0;
    Context context{};
    uint32_t id = 0;
    Before before{};
    bool has_before = true;
    Item item{};
    bool has_item = false;
    bool cancel_held = false;
  };

  Entry* Find(int token) {
    for (Entry& entry : entries_) {
      if (entry.token == token) return &entry;
    }
    return nullptr;
  }

  [[maybe_unused]] Same same_;
  std::vector<Entry> entries_;
};

// A popup an opener asked for (OnBeforePopup), waiting for the popup's
// OnAfterCreated.
struct PendingPopup {
  int popup_id = 0;
  std::string url;
  int disposition = 0;
  bool user_gesture = false;
  std::string features;
  int64_t at_ms = 0;
};

// The pending popups of each opener. The clock is the caller's: every call
// passes `now_ms` (steady milliseconds), so tests need no sleeps.
class PendingPopups {
 public:
  // A popup older than this did not cause an OnAfterCreated now.
  static constexpr int64_t kLifetimeMs = 1000;
  static constexpr size_t kLimit = 8;

  // Red stub: first in, first out; no expiry, no abort, no URL match.
  void Remember(int opener, PendingPopup popup) { entries_.push_back(Entry{opener, std::move(popup)}); }
  void Abort(int, int) {}
  bool Take(int opener, const std::string&, int64_t, PendingPopup* out) {
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].opener != opener) continue;
      *out = std::move(entries_[i].popup);
      entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
      return true;
    }
    return false;
  }

  // The opener closed.
  void Forget(int opener) {
    for (size_t i = 0; i < entries_.size();) {
      if (entries_[i].opener == opener) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
      } else {
        ++i;
      }
    }
  }

  size_t size() const { return entries_.size(); }

 private:
  struct Entry {
    int opener;
    PendingPopup popup;
  };

  std::vector<Entry> entries_;
};

}  // namespace cmux_shim

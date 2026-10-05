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
inline bool IsDownloadableUrl(std::string_view url) {
  const size_t colon = url.find(':');
  if (colon == std::string_view::npos || colon == 0) return false;
  std::string scheme;
  for (char c : url.substr(0, colon)) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.')) return false;
    scheme.push_back(c);
  }
  return scheme == "http" || scheme == "https" || scheme == "data" || scheme == "blob";
}

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

  // OnBeforeDownload: a new download; returns its token (never 0).
  int Begin(const Context& context, uint32_t id, Before before) {
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].id == id && same_(entries_[i].context, context)) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
        break;
      }
    }
    const int token = next_;
    next_ = next_ == INT32_MAX ? 1 : next_ + 1;
    Entry entry;
    entry.token = token;
    entry.context = context;
    entry.id = id;
    entry.before = before;
    entries_.push_back(entry);
    return token;
  }

  // The token of an update of `id` in `context`; 0 when the download has
  // no token (no OnBeforeDownload yet) or already ended.
  int TokenOf(const Context& context, uint32_t id) const {
    for (const Entry& entry : entries_) {
      if (entry.id == id && same_(entry.context, context)) return entry.token;
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
    if (command != 0) return Control::kUnknown;
    entry->cancel_held = true;
    return Control::kHeld;
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
  void Clear() { entries_.clear(); }
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

  Same same_;
  int next_ = 1;
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

  void Remember(int opener, PendingPopup popup) {
    Expire(popup.at_ms);
    entries_.push_back(Entry{opener, std::move(popup)});
    size_t count = 0;
    for (const Entry& entry : entries_) count += entry.opener == opener ? 1 : 0;
    for (size_t i = 0; count > kLimit && i < entries_.size();) {
      if (entries_[i].opener == opener) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
        --count;
      } else {
        ++i;
      }
    }
  }

  // Chromium refused the popup after OnBeforePopup (OnBeforePopupAborted).
  void Abort(int opener, int popup_id) {
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].opener == opener && entries_[i].popup.popup_id == popup_id) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
        return;
      }
    }
  }

  // The popup of `opener` a new tab belongs to: the oldest live one whose
  // target URL is `url` (when `url` is known and one matches), else the
  // oldest live one. False when none is live.
  bool Take(int opener, const std::string& url, int64_t now_ms, PendingPopup* out) {
    Expire(now_ms);
    size_t pick = entries_.size();
    for (size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].opener != opener) continue;
      if (!url.empty() && entries_[i].popup.url == url) {
        pick = i;
        break;
      }
      if (pick == entries_.size()) pick = i;
    }
    if (pick == entries_.size()) return false;
    if (!url.empty() && entries_[pick].popup.url != url) {
      // A known URL that matches no popup: the oldest is a guess only when
      // its own URL is unknown.
      if (!entries_[pick].popup.url.empty()) return false;
    }
    *out = std::move(entries_[pick].popup);
    entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(pick));
    return true;
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

  void Expire(int64_t now_ms) {
    for (size_t i = 0; i < entries_.size();) {
      const int64_t age = now_ms - entries_[i].popup.at_ms;
      if (age > kLifetimeMs || age < 0) {
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(i));
      } else {
        ++i;
      }
    }
  }

  std::vector<Entry> entries_;
};

}  // namespace cmux_shim

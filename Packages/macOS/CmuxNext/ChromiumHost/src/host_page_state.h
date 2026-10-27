// Page state pushes (plans/cmux-next/chrome-parity/p01-process.md, task
// p01-process-093): the Chromium Host watches the history entries of each tab
// cmux watches with the fork's cmux_tab_page_state_watch (API 31) and sends
// each changed entry's encoded page state (scroll offset, form values) to
// cmux, so cmux keeps it in the tab's frontend-browser-history-v1 record and
// a restored tab gets it back through cmux_shim_tab_restore_entries.
//
// Chrome saves the same thing: SessionService records each committed
// entry's PageState (SerializedNavigationEntry::encoded_page_state,
// components/sessions/core/serialized_navigation_entry.h) when
// NavigationEntryChanged reports it, and writes its commands on a timer that
// a change starts only when none runs, so a burst of changes is one write
// (CommandStorageManager::StartSaveTimer, kSaveDelay,
// components/sessions/core/command_storage_manager.cc). The renderer already
// sends a frame's state at most once a second
// (kDelaySecondsForContentStateSync, content/renderer/render_frame_impl.cc).
// The host does the same: a report starts the idle timer if none runs, and
// when it fires each changed entry is read once and pushed once.
//
// Wire:
//   cmux -> host  kOpTabPageStateWatch (the local export's own op id)
//                 i32 browser, i32 watch (1 on, 0 off); a token != 0 is
//                 answered with i32 the fork's result
//   host -> cmux  kOpEvent CMUX_SHIM_PAGE_STATE: browser, request = the
//                 entry's index, a = 1 when s1 is its encoded page state (0:
//                 none, or over kMaxPageStateBytes)
//
// No CEF, no AppKit: scripts/cmux-next/tests/chromium-host-dispatch.test.sh
// compiles it on Linux. UI thread only, like host_dispatch.h: no lock.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace cmux_host {

// One entry's page state in a push: with the event's other fields it stays
// under one control frame (control::kMaxBody, 64 KiB) and one TLV string.
inline constexpr size_t kMaxPageStateBytes = 60 * 1024;
// Entries a tab can have: Chromium keeps at most 50
// (NavigationControllerImpl's max_entry_count, kMaxSessionHistoryEntries).
inline constexpr int32_t kMaxPageStateEntries = 50;
// How long after a first report the changed entries go out.
inline constexpr int kPageStateIdleMs = 1000;

// The watched browsers (by Chromium id) and their entries reported since the
// last push.
class PageStatePushes {
 public:
  // Runs a task once the host is idle, kPageStateIdleMs from now (the host's
  // main run loop, browser_host_main.mm). nullptr: a report is pushed at once.
  using RequestIdle = std::function<void(std::function<void()>)>;
  // Reads and sends one entry's state.
  using Push = std::function<void(int browser, int32_t index)>;

  struct Stats {
    uint64_t reports = 0;  // reports of watched browsers' entries
    uint64_t pushes = 0;   // entries pushed
    uint64_t idles = 0;    // idle flushes that pushed
  };

  explicit PageStatePushes(Push push) : push_(std::move(push)) {}
  ~PageStatePushes() { *alive_ = false; }
  PageStatePushes(const PageStatePushes&) = delete;
  PageStatePushes& operator=(const PageStatePushes&) = delete;

  void SetRequestIdle(RequestIdle request_idle) { request_idle_ = std::move(request_idle); }

  // No bound of its own: the fork refuses a browser that is not live, and a
  // closed one is forgotten.
  void Watch(int browser) { watched_.insert(browser); }
  // Drops the browser's watch and its waiting entries (also when it closed).
  void Forget(int browser) {
    if (watched_.erase(browser) == 0) return;
    std::erase_if(waiting_, [browser](const Entry& entry) { return entry.browser == browser; });
  }
  bool watching(int browser) const { return watched_.count(browser) != 0; }
  size_t watches() const { return watched_.size(); }
  size_t waiting() const { return waiting_.size(); }

  // The fork reported entry `index` of `browser` committed or changed.
  // Reports of an unwatched browser or an index past kMaxPageStateEntries
  // are dropped; an entry already waiting waits once.
  void Reported(int browser, int32_t index) {
    if (!watching(browser) || index < 0 || index >= kMaxPageStateEntries) return;
    ++stats_.reports;
    const Entry entry{browser, index};
    for (const Entry& waiting : waiting_) {
      if (waiting == entry) return;
    }
    waiting_.push_back(entry);
    if (!request_idle_) return Flush();
    if (idle_requested_) return;
    idle_requested_ = true;
    request_idle_([this, alive = alive_] {
      if (!*alive) return;
      idle_requested_ = false;
      Flush();
    });
  }

  // Pushes every waiting entry of a still watched browser, in report order.
  void Flush() {
    std::vector<Entry> entries;
    entries.swap(waiting_);
    if (entries.empty()) return;
    ++stats_.idles;
    for (const Entry& entry : entries) {
      // A push may forget a browser (its tab closed in the event's turn).
      if (!watching(entry.browser)) continue;
      ++stats_.pushes;
      push_(entry.browser, entry.index);
    }
  }

  const Stats& stats() const { return stats_; }

 private:
  struct Entry {
    int browser;
    int32_t index;
    bool operator==(const Entry&) const = default;
  };

  Push push_;
  RequestIdle request_idle_;
  std::unordered_set<int> watched_;
  // At most watches() * kMaxPageStateEntries, each once.
  std::vector<Entry> waiting_;
  bool idle_requested_ = false;
  // The requested idle task flushes only while this object lives.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  Stats stats_;
};

}  // namespace cmux_host

// Checks the shim's download tokens, download URL schemes and pending popups
// (CEFShim/src/download_state.h, no CEF needed;
// scripts/cmux-next/test-shim-downloads-cpp.sh).
#include <cstdio>
#include <string>

#include "../src/download_state.h"

using cmux_shim::DownloadTable;
using cmux_shim::IsDownloadableUrl;
using cmux_shim::PendingPopup;
using cmux_shim::PendingPopups;

static int failures = 0;
static int cases = 0;

static void Check(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// Contexts are profile numbers; callbacks are labels.
static bool SameProfile(const int& a, const int& b) { return a == b; }
using Table = DownloadTable<int, std::string, std::string>;

// P2-1: Chromium counts ids per profile. Profile B's download 1 after
// profile A's download 1 finished is a new download with its own token.
static void TokensAreUniqueAcrossProfiles() {
  Table table(SameProfile);
  const int a = table.Begin(1, 1, "before-a");
  Check(a != 0, "a token is never 0");
  table.Finish(a);
  const int b = table.Begin(2, 1, "before-b");
  Check(b != 0 && b != a, "profile B's id 1 gets its own token");
  Check(table.TokenOf(2, 1) == b, "profile B's updates find B");
  Check(table.TokenOf(1, 1) == 0, "profile A's finished id 1 is ignored");
  // Both profiles running id 1 at once: commands reach the right one.
  const int a2 = table.Begin(1, 7, "before-a2");
  const int b2 = table.Begin(2, 7, "before-b2");
  Check(a2 != b2, "two running id 7s have two tokens");
  Check(!table.Running(a2, "item-a2"), "no held cancel for a2");
  Check(!table.Running(b2, "item-b2"), "no held cancel for b2");
  std::string item;
  Check(table.Command(b2, 0, &item) == Table::Control::kApply && item == "item-b2", "cancel B reaches B");
  Check(table.Command(a2, 1, &item) == Table::Control::kApply && item == "item-a2", "pause A reaches A");
  table.Finish(b2);
  Check(table.TokenOf(2, 7) == 0 && table.TokenOf(1, 7) == a2, "B's DONE does not end A");
  Check(table.Command(b2, 0, &item) == Table::Control::kUnknown, "a finished token takes no command");
}

static void TokensAreNeverReused() {
  Table table(SameProfile);
  int last = 0;
  bool increasing = true;
  for (int i = 0; i < 50; ++i) {
    const int token = table.Begin(1, 1, "b");
    increasing = increasing && token > last;
    last = token;
    table.Finish(token);
  }
  Check(increasing, "tokens only grow");
  Check(table.size() == 0, "finished downloads leave the table");
}

static void ContinueTakesTheCallbackOnce() {
  Table table(SameProfile);
  const int token = table.Begin(3, 9, "before");
  std::string before;
  Check(table.TakeBefore(token, &before) && before == "before", "continue gets the callback");
  Check(!table.TakeBefore(token, &before), "a second continue gets nothing");
  Check(!table.TakeBefore(token + 100, &before), "an unknown token gets nothing");
}

// P3 (3): a cancel before the first update is held and applied then.
static void AnEarlyCancelIsHeld() {
  Table table(SameProfile);
  const int token = table.Begin(1, 4, "before");
  std::string item;
  Check(table.Command(token, 0, &item) == Table::Control::kHeld, "an early cancel is held");
  Check(table.Command(token, 1, &item) == Table::Control::kUnknown, "an early pause is not");
  Check(table.Running(token, "item"), "the first update applies the held cancel");
  Check(!table.Running(token, "item"), "only once");
  Check(table.Command(token, 9, &item) == Table::Control::kUnknown, "unknown commands are refused");
}

// P3 (6): Clear releases every callback before CefShutdown.
static void ClearReleasesEverything() {
  Table table(SameProfile);
  table.Begin(1, 1, "a");
  table.Begin(2, 1, "b");
  table.Clear();
  Check(table.size() == 0 && table.TokenOf(1, 1) == 0, "clear empties the table");
}

// P3 (8): only http, https, data and blob.
static void OnlyWebSchemesDownload() {
  Check(IsDownloadableUrl("https://e.com/a.zip"), "https");
  Check(IsDownloadableUrl("HTTP://e.com/a"), "http, any case");
  Check(IsDownloadableUrl("data:text/plain,x"), "data");
  Check(IsDownloadableUrl("blob:https://e.com/1234"), "blob");
  Check(!IsDownloadableUrl("file:///etc/passwd"), "never file");
  Check(!IsDownloadableUrl("FILE:///etc/passwd"), "never file, any case");
  Check(!IsDownloadableUrl("javascript:alert(1)"), "no javascript");
  Check(!IsDownloadableUrl("chrome://settings"), "no chrome");
  Check(!IsDownloadableUrl("ftp://e.com/a"), "no ftp");
  Check(!IsDownloadableUrl("/etc/passwd"), "no bare path");
  Check(!IsDownloadableUrl(""), "not empty");
  Check(!IsDownloadableUrl(":x"), "no empty scheme");
}

static PendingPopup Popup(int id, const std::string& url, int disposition, bool gesture, int64_t at) {
  PendingPopup popup;
  popup.popup_id = id;
  popup.url = url;
  popup.disposition = disposition;
  popup.user_gesture = gesture;
  popup.at_ms = at;
  return popup;
}

// P3 (2): the popup a new tab belongs to matches by target URL, refused
// popups drop out, and stale ones expire after about 1 s.
static void PopupsMatchByURL() {
  PendingPopups popups;
  popups.Remember(5, Popup(1, "https://a.com/", 3, true, 1000));
  popups.Remember(5, Popup(2, "https://b.com/", 4, false, 1010));
  PendingPopup got;
  Check(popups.Take(5, "https://b.com/", 1100, &got) && got.popup_id == 2 && got.disposition == 4 && !got.user_gesture,
        "the tab for b.com gets b.com's disposition and gesture");
  Check(popups.Take(5, "https://a.com/", 1100, &got) && got.popup_id == 1 && got.user_gesture, "then a.com's");
  Check(!popups.Take(5, "", 1100, &got), "nothing left");
}

static void APopupForAnotherURLIsNotTaken() {
  PendingPopups popups;
  popups.Remember(5, Popup(1, "https://a.com/", 3, true, 0));
  PendingPopup got;
  Check(!popups.Take(5, "https://other.com/", 10, &got), "a known other URL takes nothing");
  Check(popups.Take(5, "", 10, &got) && got.popup_id == 1, "an unknown URL takes the oldest");
}

static void RefusedPopupsDrop() {
  PendingPopups popups;
  popups.Remember(5, Popup(1, "https://a.com/", 3, true, 0));
  popups.Remember(5, Popup(2, "https://a.com/", 4, false, 0));
  popups.Abort(5, 1);
  PendingPopup got;
  Check(popups.Take(5, "https://a.com/", 10, &got) && got.popup_id == 2, "a refused popup never matches a tab");
}

static void StalePopupsExpire() {
  PendingPopups popups;
  popups.Remember(5, Popup(1, "https://a.com/", 3, true, 0));
  PendingPopup got;
  Check(!popups.Take(5, "https://a.com/", PendingPopups::kLifetimeMs + 1, &got), "older than the lifetime: gone");
  popups.Remember(5, Popup(2, "https://a.com/", 3, true, 5000));
  Check(popups.Take(5, "https://a.com/", 5000 + PendingPopups::kLifetimeMs, &got) && got.popup_id == 2,
        "at the lifetime: still live");
  popups.Remember(5, Popup(3, "", 3, true, 9000));
  popups.Remember(6, Popup(4, "", 3, true, 9000));
  popups.Forget(5);
  Check(!popups.Take(5, "", 9001, &got), "a closed opener's popups are gone");
  Check(popups.Take(6, "", 9001, &got) && got.popup_id == 4, "other openers keep theirs");
}

int main() {
  TokensAreUniqueAcrossProfiles();
  TokensAreNeverReused();
  ContinueTakesTheCallbackOnce();
  AnEarlyCancelIsHeld();
  ClearReleasesEverything();
  OnlyWebSchemesDownload();
  PopupsMatchByURL();
  APopupForAnotherURLIsNotTaken();
  RefusedPopupsDrop();
  StalePopupsExpire();
  std::printf("%d/%d cases passed\n", cases - failures, cases);
  return failures == 0 ? 0 : 1;
}

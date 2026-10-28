// The Chromium Host's client ids (src/host_client_ids.h, task 019 of
// plans/cmux-next/chrome-parity/p01-process.md): ops reach Chromium with
// Chromium's ids, events reach cmux with the ids cmux minted, for create_window
// (bound by its AFTER_CREATED), tab_add and tab_duplicate (bound by the call,
// whose OnAfterCreated waits for the bind), devtools_call, the opener of a
// popup and BEFORE_CLOSE; a refused create or call reaches cmux as an event.
// Built and run by scripts/cmux-next/tests/chromium-host-client-ids.test.sh;
// needs no CEF.
#include "host_client_ids.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

#include "cmux_cef_shim.h"

namespace {

using cmux_host::ClientIds;
using Event = cmux_host::ClientIds::Event;
using Outcome = cmux_host::ClientIds::Outcome;
namespace mint = cmux_host::mint;

int failures = 0;
#define CHECK(cond)                                                                 \
  do {                                                                              \
    if (!(cond)) {                                                                  \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                                   \
    }                                                                               \
  } while (0)

constexpr int32_t kWindow = mint::kFirstBrowserID;     // create_window's minted id
constexpr int32_t kAdded = mint::kFirstBrowserID + 1;  // tab_add's
constexpr int32_t kCopy = mint::kFirstBrowserID + 2;   // tab_duplicate's

Event After(int browser, int request, int64_t b = 0) {
  return Event{CMUX_SHIM_AFTER_CREATED, browser, request, 7, b, {}, {}};
}

Event Of(int kind, int browser, int request = 0, int64_t a = 0, int64_t b = 0) {
  return Event{kind, browser, request, a, b, {}, {}};
}

int32_t Opener(int64_t b) {
  return static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint64_t>(b) >> 32));
}

// A map whose events land in `sent`.
struct Fixture {
  std::vector<Event> sent;
  ClientIds ids{[this](const Event& event) { sent.push_back(event); }};

  // The one event a shim event becomes.
  Event Through(const Event& chromium) {
    sent.clear();
    CHECK(ids.FromShim(chromium));
    CHECK(sent.size() == 1);
    return sent.empty() ? Event{} : sent.back();
  }
};

// create_window: the id is minted before Chromium has a browser; ops naming it
// reach no browser until AFTER_CREATED(request) binds it, and that event and
// every later one carry the minted id.
void CreateWindowBindsAtItsAfterCreated() {
  Fixture f;
  CHECK(f.ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBound);
  CHECK(f.sent.empty());
  CHECK(f.ids.pending_creates() == 1);
  CHECK(f.ids.Browser(kWindow) == 0);
  CHECK(f.Through(After(4, 42)).browser_id == 4);  // another request's browser keeps Chromium's id
  const Event created = f.Through(After(5, 41));
  CHECK(created.browser_id == kWindow);
  CHECK(created.request == 41 && created.a == 7);
  CHECK(f.ids.pending_creates() == 0);
  CHECK(f.ids.Browser(kWindow) == 5);
  CHECK(f.Through(Of(CMUX_SHIM_TITLE, 5)).browser_id == kWindow);
  CHECK(f.Through(Of(CMUX_SHIM_TAB_EVENT, 5, 0, 9, 1)).browser_id == kWindow);
}

// The real shim runs OnAfterCreated inside tab_add and tab_duplicate, before
// the case binds the minted id: the map holds that event until EndCall, then
// sends it under the minted id, never under Chromium's.
void AnAfterCreatedInsideTheCallWaitsForTheBind() {
  Fixture f;
  f.ids.BeginCall();
  CHECK(f.ids.FromShim(After(6, 0)));                     // inside cmux_shim_tab_add
  CHECK(f.ids.FromShim(Of(CMUX_SHIM_TAB_EVENT, 6, 1)));  // and the strip's insertion
  CHECK(f.sent.empty());
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(f.sent.empty());
  f.ids.EndCall();
  CHECK(f.sent.size() == 2);
  for (const Event& event : f.sent) CHECK(event.browser_id == kAdded);
  CHECK(f.sent.size() == 2 && f.sent[0].kind == CMUX_SHIM_AFTER_CREATED);
  // The same for tab_duplicate, and an event after the call goes straight out.
  f.sent.clear();
  f.ids.BeginCall();
  CHECK(f.ids.FromShim(After(8, 0)));
  CHECK(f.ids.Bind(kCopy, 8) == Outcome::kBound);
  f.ids.EndCall();
  CHECK(f.sent.size() == 1 && f.sent[0].browser_id == kCopy);
  CHECK(f.Through(Of(CMUX_SHIM_TITLE, 8)).browser_id == kCopy);
  CHECK(f.ids.browsers() == 2);
}

// A refused tab_add or tab_duplicate ends with CREATE_FAILED(minted), after
// what the call emitted: cmux keeps the tab and shows the failure, as in
// process after the shim's 0. Its id names no browser.
void ARefusedTabCreationSendsCreateFailed() {
  Fixture f;
  f.ids.BeginCall();
  CHECK(f.ids.FromShim(Of(CMUX_SHIM_TITLE, 3)));
  CHECK(f.ids.Bind(kAdded, 0) == Outcome::kRefused);
  CHECK(f.sent.empty());
  f.ids.EndCall();
  CHECK(f.sent.size() == 2);
  if (f.sent.size() == 2) {
    CHECK(f.sent[0].kind == CMUX_SHIM_TITLE && f.sent[0].browser_id == 3);
    CHECK(f.sent[1].kind == mint::kEventCreateFailed);
    CHECK(f.sent[1].browser_id == kAdded && f.sent[1].request == 0);
  }
  CHECK(f.ids.Browser(kAdded) == 0);
  CHECK(f.ids.browsers() == 0);
}

// A refused create_window sends CREATE_FAILED(minted, request): cmux stops
// waiting for that window and its tabs show the failure.
void ARefusedCreateWindowSendsCreateFailedWithItsRequest() {
  Fixture f;
  f.ids.BeginCall();
  CHECK(f.ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 0) == Outcome::kRefused);
  f.ids.EndCall();
  CHECK(f.sent.size() == 1);
  if (f.sent.size() == 1) {
    CHECK(f.sent[0].kind == mint::kEventCreateFailed);
    CHECK(f.sent[0].browser_id == kWindow && f.sent[0].request == 41);
  }
  CHECK(f.ids.Browser(kWindow) == 0);
  CHECK(f.ids.pending_creates() == 0);
  CHECK(f.Through(After(5, 41)).browser_id == 5);
}

// The peer's ids must be minted ones, each used once; a bad one sends nothing.
void AnIdOutsideTheMintedRangeOrUsedTwiceIsBad() {
  Fixture f;
  CHECK(f.ids.Bind(5, 6) == Outcome::kBad);
  CHECK(f.ids.Bind(5, 0) == Outcome::kBad);
  CHECK(f.ids.BindOnEvent(mint::kFirstBrowserID - 1, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(f.ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 0, 1) == Outcome::kBad);
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(f.ids.Bind(kAdded, 9) == Outcome::kBad);
  CHECK(f.ids.Bind(kCopy, 6) == Outcome::kBad);  // Chromium's 6 is kAdded's
  CHECK(f.ids.BindOnEvent(kAdded, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(f.ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBound);
  CHECK(f.ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 43, 1) == Outcome::kBad);
  CHECK(f.ids.BindOnEvent(kCopy, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kEndDevToolsID, 3) == Outcome::kBad);
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kFirstBrowserID, 3) == Outcome::kBad);
  CHECK(f.sent.empty());
}

// Pending creations are bounded: a peer cannot grow the host without limit.
void PendingCreationsAreBounded() {
  Fixture f;
  for (size_t i = 0; i < ClientIds::kMaxPendingCreates; ++i) {
    const int32_t n = static_cast<int32_t>(i);
    CHECK(f.ids.BindOnEvent(mint::kFirstBrowserID + n, CMUX_SHIM_AFTER_CREATED, n + 1, 1) == Outcome::kBound);
  }
  const int32_t past = static_cast<int32_t>(ClientIds::kMaxPendingCreates);
  CHECK(f.ids.BindOnEvent(mint::kFirstBrowserID + past, CMUX_SHIM_AFTER_CREATED, past + 1, 1) == Outcome::kBad);
}

// A tab Chromium opened itself (a popup, target=_blank) keeps Chromium's id
// (chromium_host_mint.h), and its opener, a tab cmux minted, reaches cmux by
// its minted id.
void APopupNamesItsOpenerByTheMintedId() {
  Fixture f;
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  const int64_t flags = (1 << 16) | 3;  // a user gesture, NEW_FOREGROUND_TAB
  const Event popup = f.Through(After(12, 0, (int64_t{6} << 32) | flags));
  CHECK(popup.browser_id == 12);
  CHECK(Opener(popup.b) == kAdded);
  CHECK((popup.b & 0xffffffff) == flags);
  CHECK(f.ids.Browser(12) == 12);
  CHECK(f.Through(After(13, 0, 3)).b == 3);                          // no opener: b as it was
  CHECK(Opener(f.Through(After(14, 0, int64_t{12} << 32)).b) == 12);  // an opener Chromium made
}

// Chromium's counter reaching the minted range would make one id name two
// browsers: the map refuses the event, and the host ends.
void AChromiumIdInTheMintedRangeEndsTheHost() {
  Fixture f;
  CHECK(!f.ids.FromShim(After(mint::kFirstBrowserID, 0)));
  CHECK(!f.ids.FromShim(Of(CMUX_SHIM_DEVTOOLS_OPENED, 6, 0, mint::kFirstBrowserID + 5)));
  CHECK(f.sent.empty());
}

// devtools_call's minted message id comes back in DEVTOOLS_RESULT, once. A
// refused call is DEVTOOLS_RESULT(the caller's browser, minted, a = 0), so its
// waiter fails at once.
void DevToolsResultsCarryTheMintedMessageId() {
  Fixture f;
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID, 3) == Outcome::kBound);
  CHECK(f.sent.empty());
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID + 1, 0) == Outcome::kRefused);
  CHECK(f.sent.size() == 1);
  if (f.sent.size() == 1) {
    CHECK(f.sent[0].kind == CMUX_SHIM_DEVTOOLS_RESULT);
    CHECK(f.sent[0].browser_id == kAdded && f.sent[0].request == mint::kFirstDevToolsID + 1 && f.sent[0].a == 0);
  }
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID + 2, 3) == Outcome::kBad);  // the shim reused 3
  const Event result = f.Through(Of(CMUX_SHIM_DEVTOOLS_RESULT, 6, 3, 1));
  CHECK(result.browser_id == kAdded && result.request == mint::kFirstDevToolsID);
  CHECK(f.ids.devtools_calls() == 0);
  CHECK(f.Through(Of(CMUX_SHIM_DEVTOOLS_RESULT, 6, 3, 1)).request == 3);
  // A DevTools browser is Chromium's own; its inspected page is cmux's.
  const Event opened = f.Through(Of(CMUX_SHIM_DEVTOOLS_OPENED, 6, 0, 20, 1));
  CHECK(opened.browser_id == kAdded && opened.a == 20 && opened.b == 1);
}

// WINDOW_REQUEST_RESULT (task 031) names the source and the anchor whose
// window gets the new tab by cmux's ids; the window id in `request` is
// Chromium's on both sides.
void AWindowRequestResultNamesItsAnchorByTheMintedId() {
  Fixture f;
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  const Event result = f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 77, 6, CMUX_SHIM_WINDOW_INSERT));
  CHECK(result.browser_id == kAdded && result.request == 77 && result.a == kAdded);
  CHECK(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 0, 0, 0, CMUX_SHIM_WINDOW_OFF_THE_RECORD)).a == 0);
}

int32_t Tab(int64_t b) {
  return static_cast<int32_t>(static_cast<uint64_t>(b) >> 32);
}

// An INSERT's result carries the id the host minted for its tab, from the
// host's range; the tab's AFTER_CREATED in the anchor's window names it by
// that id, and ops on the id reach Chromium's tab.
void AnInsertsTabIsNamedByTheIdItsResultCarried() {
  Fixture f;
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  const int64_t flags = CMUX_SHIM_WINDOW_INSERT | (CMUX_SHIM_NEW_TAB_POPUP << 8) | (int64_t{1} << 31);
  const Event result = f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 77, 6, flags));
  const int32_t minted = Tab(result.b);
  CHECK(minted == mint::kFirstHostBrowserID);
  CHECK((result.b & 0xffffffff) == flags);
  CHECK(f.ids.pending_window_request_tabs() == 1);
  const Event created = f.Through(Of(CMUX_SHIM_AFTER_CREATED, 12, 0, 77, (int64_t{6} << 32) | 5));
  CHECK(created.browser_id == minted);
  CHECK(Opener(created.b) == kAdded);
  CHECK(f.ids.Browser(minted) == 12 && f.ids.ClientOf(12) == minted);
  CHECK(f.ids.pending_window_request_tabs() == 0);
  CHECK(f.Through(Of(CMUX_SHIM_TITLE, 12)).browser_id == minted);
  CHECK(f.Through(Of(CMUX_SHIM_BEFORE_CLOSE, 12)).browser_id == minted);
  CHECK(f.ids.Browser(minted) == 0);
}

// Only an INSERT mints; a tab is matched by its window, oldest first, and by
// its opener while it is in no window yet; another tab keeps Chromium's id.
void OnlyAnInsertsTabTakesAMintedId() {
  Fixture f;
  CHECK(Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 0, 0, CMUX_SHIM_WINDOW_OPEN_IN_NEW_TAB)).b) == 0);
  CHECK(Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 0, 6, CMUX_SHIM_WINDOW_INSERT)).b) == 0);  // no window
  const int32_t first = Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 77, 6, CMUX_SHIM_WINDOW_INSERT)).b);
  const int32_t second = Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 8, 78, 8, CMUX_SHIM_WINDOW_INSERT)).b);
  const int32_t third = Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 77, 6, CMUX_SHIM_WINDOW_INSERT)).b);
  CHECK(first == mint::kFirstHostBrowserID && second == first + 1 && third == first + 2);
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 20, 0, 79)).browser_id == 20);  // a window with no insert
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 21, 0, 77)).browser_id == first);
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 22, 0, 0, int64_t{8} << 32)).browser_id == second);  // by opener
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 23, 0, 77)).browser_id == third);
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 24, 0, 77)).browser_id == 24);
  CHECK(f.ids.pending_window_request_tabs() == 0);
}

// A tab cmux minted itself keeps that id even when an insert waits in its
// window: tab_add binds it inside the call, before the held AFTER_CREATED.
void ATabAddedInsideACallKeepsItsOwnId() {
  Fixture f;
  const int32_t minted = Tab(f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, 77, 6, CMUX_SHIM_WINDOW_INSERT)).b);
  f.sent.clear();
  f.ids.BeginCall();
  CHECK(f.ids.FromShim(Of(CMUX_SHIM_AFTER_CREATED, 30, 0, 77)));
  CHECK(f.ids.Bind(kAdded, 30) == Outcome::kBound);
  f.ids.EndCall();
  CHECK(f.sent.size() == 1 && f.sent[0].browser_id == kAdded);
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 31, 0, 77)).browser_id == minted);
}

// An insert whose tab never came waits until kMaxPending newer ones push it out.
void WaitingInsertsAreBounded() {
  Fixture f;
  const size_t bound = cmux_host::WindowRequestTabIds::kMaxPending;
  for (size_t n = 0; n <= bound; ++n) {
    f.Through(Of(CMUX_SHIM_WINDOW_REQUEST_RESULT, 6, static_cast<int>(100 + n), 6, CMUX_SHIM_WINDOW_INSERT));
  }
  CHECK(f.ids.pending_window_request_tabs() == bound);
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 40, 0, 100)).browser_id == 40);  // the oldest left
  CHECK(f.Through(Of(CMUX_SHIM_AFTER_CREATED, 41, 0, 101)).browser_id == mint::kFirstHostBrowserID + 1);
}

// BEFORE_CLOSE carries the minted id; then the id names no browser, so a late
// op is dropped, and Chromium's id is its own again.
void BeforeCloseForgetsTheBrowser() {
  Fixture f;
  CHECK(f.ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(f.ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID, 3) == Outcome::kBound);
  CHECK(f.Through(Of(CMUX_SHIM_BEFORE_CLOSE, 6)).browser_id == kAdded);
  CHECK(f.ids.Browser(kAdded) == 0);
  CHECK(f.ids.ClientOf(6) == 6);
  CHECK(f.ids.browsers() == 0 && f.ids.devtools_calls() == 0);
}

}  // namespace

int main() {
  CreateWindowBindsAtItsAfterCreated();
  AnAfterCreatedInsideTheCallWaitsForTheBind();
  ARefusedTabCreationSendsCreateFailed();
  ARefusedCreateWindowSendsCreateFailedWithItsRequest();
  AnIdOutsideTheMintedRangeOrUsedTwiceIsBad();
  PendingCreationsAreBounded();
  APopupNamesItsOpenerByTheMintedId();
  AChromiumIdInTheMintedRangeEndsTheHost();
  DevToolsResultsCarryTheMintedMessageId();
  AWindowRequestResultNamesItsAnchorByTheMintedId();
  AnInsertsTabIsNamedByTheIdItsResultCarried();
  OnlyAnInsertsTabTakesAMintedId();
  ATabAddedInsideACallKeepsItsOwnId();
  WaitingInsertsAreBounded();
  BeforeCloseForgetsTheBrowser();
  if (failures != 0) {
    std::fprintf(stderr, "host_client_ids_test: %d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::puts("host_client_ids_test: ok");
  return EXIT_SUCCESS;
}

// The Chromium Host's client ids (src/host_client_ids.h, task 019 of
// plans/cmux-next/chrome-parity/p01-process.md): ops reach Chromium with
// Chromium's ids, events reach cmux with the ids cmux minted, for create_window
// (bound by its AFTER_CREATED), tab_add and tab_duplicate (bound by the call),
// devtools_call, the opener of a popup and BEFORE_CLOSE. Built and run by
// scripts/cmux-next/tests/chromium-host-client-ids.test.sh; needs no CEF.
#include "host_client_ids.h"

#include <cstdio>
#include <cstdlib>

#include "cmux_cef_shim.h"

namespace {

using cmux_host::ClientIds;
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

ClientIds::Event After(int browser, int request, int64_t b = 0) {
  return ClientIds::Event{CMUX_SHIM_AFTER_CREATED, browser, request, 7, b};
}

ClientIds::Event Of(int kind, int browser, int request = 0, int64_t a = 0, int64_t b = 0) {
  return ClientIds::Event{kind, browser, request, a, b};
}

int32_t Opener(int64_t b) {
  return static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint64_t>(b) >> 32));
}

// create_window: the id is minted before Chromium has a browser; ops naming it
// reach no browser until AFTER_CREATED(request) binds it, and that event and
// every later one carry the minted id.
void CreateWindowBindsAtItsAfterCreated() {
  ClientIds ids;
  CHECK(ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBound);
  CHECK(ids.pending_creates() == 1);
  CHECK(ids.Browser(kWindow) == 0);
  CHECK(ids.ToClient(After(4, 42)).browser_id == 4);  // another request's browser keeps Chromium's id
  const ClientIds::Event created = ids.ToClient(After(5, 41));
  CHECK(created.browser_id == kWindow);
  CHECK(created.request == 41 && created.a == 7);
  CHECK(ids.pending_creates() == 0);
  CHECK(ids.Browser(kWindow) == 5);
  CHECK(ids.ToClient(Of(CMUX_SHIM_TITLE, 5)).browser_id == kWindow);
  CHECK(ids.ToClient(Of(CMUX_SHIM_TAB_EVENT, 5, 0, 9, 1)).browser_id == kWindow);
}

// tab_add and tab_duplicate return Chromium's id inside the call: bound at once.
void TabAddAndDuplicateBindAtTheCall() {
  ClientIds ids;
  CHECK(ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(ids.Bind(kCopy, 8) == Outcome::kBound);
  CHECK(ids.Browser(kAdded) == 6 && ids.Browser(kCopy) == 8);
  // Their OnAfterCreated (request 0), held by HostContext until the case bound the id.
  CHECK(ids.ToClient(After(6, 0)).browser_id == kAdded);
  CHECK(ids.ToClient(After(8, 0)).browser_id == kCopy);
  CHECK(ids.browsers() == 2);
}

// A refused creation binds nothing; its id never names a browser.
void ARefusedCreationNamesNoBrowser() {
  ClientIds ids;
  CHECK(ids.Bind(kAdded, 0) == Outcome::kRefused);
  CHECK(ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 0) == Outcome::kRefused);
  CHECK(ids.Browser(kAdded) == 0 && ids.Browser(kWindow) == 0);
  CHECK(ids.ToClient(After(5, 41)).browser_id == 5);
  CHECK(ids.browsers() == 0 && ids.pending_creates() == 0);
}

// The peer's ids must be minted ones, each used once.
void AnIdOutsideTheMintedRangeOrUsedTwiceIsBad() {
  ClientIds ids;
  CHECK(ids.Bind(5, 6) == Outcome::kBad);
  CHECK(ids.BindOnEvent(mint::kFirstBrowserID - 1, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 0, 1) == Outcome::kBad);
  CHECK(ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(ids.Bind(kAdded, 9) == Outcome::kBad);
  CHECK(ids.Bind(kCopy, 6) == Outcome::kBad);  // Chromium's 6 is kAdded's
  CHECK(ids.BindOnEvent(kAdded, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBound);
  CHECK(ids.BindOnEvent(kWindow, CMUX_SHIM_AFTER_CREATED, 43, 1) == Outcome::kBad);
  CHECK(ids.BindOnEvent(kCopy, CMUX_SHIM_AFTER_CREATED, 41, 1) == Outcome::kBad);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kEndDevToolsID, 3) == Outcome::kBad);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kFirstBrowserID, 3) == Outcome::kBad);
}

// Pending creations are bounded: a peer cannot grow the host without limit.
void PendingCreationsAreBounded() {
  ClientIds ids;
  for (size_t i = 0; i < ClientIds::kMaxPendingCreates; ++i) {
    const int32_t n = static_cast<int32_t>(i);
    CHECK(ids.BindOnEvent(mint::kFirstBrowserID + n, CMUX_SHIM_AFTER_CREATED, n + 1, 1) == Outcome::kBound);
  }
  const int32_t past = static_cast<int32_t>(ClientIds::kMaxPendingCreates);
  CHECK(ids.BindOnEvent(mint::kFirstBrowserID + past, CMUX_SHIM_AFTER_CREATED, past + 1, 1) == Outcome::kBad);
}

// A tab Chromium opened itself (a popup, target=_blank) keeps Chromium's id,
// and its opener, a tab cmux minted, reaches cmux by its minted id.
void APopupNamesItsOpenerByTheMintedId() {
  ClientIds ids;
  CHECK(ids.Bind(kAdded, 6) == Outcome::kBound);
  const int64_t flags = (1 << 16) | 3;  // a user gesture, NEW_FOREGROUND_TAB
  const ClientIds::Event popup = ids.ToClient(After(12, 0, (int64_t{6} << 32) | flags));
  CHECK(popup.browser_id == 12);
  CHECK(Opener(popup.b) == kAdded);
  CHECK((popup.b & 0xffffffff) == flags);
  CHECK(ids.Browser(12) == 12);
  CHECK(ids.ToClient(After(13, 0, 3)).b == 3);                        // no opener: b as it was
  CHECK(Opener(ids.ToClient(After(14, 0, int64_t{12} << 32)).b) == 12);  // an opener Chromium made
}

// devtools_call's minted message id comes back in DEVTOOLS_RESULT, once; a
// refused call is the caller's DEVTOOLS_RESULT with a = 0.
void DevToolsResultsCarryTheMintedMessageId() {
  ClientIds ids;
  CHECK(ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID, 3) == Outcome::kBound);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID + 1, 0) == Outcome::kRefused);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID + 2, 3) == Outcome::kBad);  // the shim reused 3
  const ClientIds::Event result = ids.ToClient(Of(CMUX_SHIM_DEVTOOLS_RESULT, 6, 3, 1));
  CHECK(result.browser_id == kAdded && result.request == mint::kFirstDevToolsID);
  CHECK(ids.devtools_calls() == 0);
  CHECK(ids.ToClient(Of(CMUX_SHIM_DEVTOOLS_RESULT, 6, 3, 1)).request == 3);
  // A DevTools browser is Chromium's own; its inspected page is cmux's.
  const ClientIds::Event opened = ids.ToClient(Of(CMUX_SHIM_DEVTOOLS_OPENED, 6, 0, 20, 1));
  CHECK(opened.browser_id == kAdded && opened.a == 20 && opened.b == 1);
}

// BEFORE_CLOSE carries the minted id; then the id names no browser, so a late
// op is dropped, and Chromium's id is its own again.
void BeforeCloseForgetsTheBrowser() {
  ClientIds ids;
  CHECK(ids.Bind(kAdded, 6) == Outcome::kBound);
  CHECK(ids.BindDevToolsCall(kAdded, mint::kFirstDevToolsID, 3) == Outcome::kBound);
  CHECK(ids.ToClient(Of(CMUX_SHIM_BEFORE_CLOSE, 6)).browser_id == kAdded);
  CHECK(ids.Browser(kAdded) == 0);
  CHECK(ids.ClientOf(6) == 6);
  CHECK(ids.browsers() == 0 && ids.devtools_calls() == 0);
}

}  // namespace

int main() {
  CreateWindowBindsAtItsAfterCreated();
  TabAddAndDuplicateBindAtTheCall();
  ARefusedCreationNamesNoBrowser();
  AnIdOutsideTheMintedRangeOrUsedTwiceIsBad();
  PendingCreationsAreBounded();
  APopupNamesItsOpenerByTheMintedId();
  DevToolsResultsCarryTheMintedMessageId();
  BeforeCloseForgetsTheBrowser();
  if (failures != 0) {
    std::fprintf(stderr, "host_client_ids_test: %d failure(s)\n", failures);
    return EXIT_FAILURE;
  }
  std::puts("host_client_ids_test: ok");
  return EXIT_SUCCESS;
}

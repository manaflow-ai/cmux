// Checks the remote shim's page state exports (client/remote_shim_page_state.mm,
// task p01-process-093) against a fake transport: a watch is sent once and
// only with a host, a push keeps the entry's state before fn runs, so fn reads
// it in its turn; a push with none or over the bound forgets the entry; a
// stop, a close or the host's exit keeps nothing. Built and run by
// scripts/cmux-next/tests/remote-shim-local.test.sh.
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "../client/remote_shim_page_state.h"
#include "../src/host_page_state.h"

namespace {

namespace page_state = cmux_remote::page_state;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

struct FakeTransport {
  bool accepts = true;
  std::vector<std::pair<int, bool>> sent;
};

bool SendWatch(void* context, int browser, bool watching) {
  auto* t = static_cast<FakeTransport*>(context);
  if (!t->accepts) return false;
  t->sent.emplace_back(browser, watching);
  return true;
}

std::optional<std::string> Read(int browser, int index) {
  char* state = cmux_shim_tab_entry_page_state(browser, index);
  if (state == nullptr) return std::nullopt;
  std::string out(state);
  std::free(state);  // the remote shim's cmux_shim_free
  return out;
}

struct Call {
  int browser;
  int index;
  std::optional<std::string> state;
};
std::vector<Call> calls;

void OnWatch(void*, int browser, int index) { calls.push_back({browser, index, Read(browser, index)}); }

void StopsItself(void*, int browser, int) { cmux_shim_tab_page_state_watch(browser, nullptr, nullptr); }

}  // namespace

int main() {
  Check(cmux_shim_tab_page_state_watch(7, &OnWatch, nullptr) == 0, "no host: the watch answers 0");

  FakeTransport t;
  const page_state::Transport transport{&t, &SendWatch};
  page_state::Attach(&transport);
  t.accepts = false;
  Check(cmux_shim_tab_page_state_watch(7, &OnWatch, nullptr) == 0, "a refused send answers 0");
  t.accepts = true;
  Check(cmux_shim_tab_page_state_watch(7, &OnWatch, nullptr) == 1, "a watch with a host answers 1");
  Check(cmux_shim_tab_page_state_watch(7, &OnWatch, nullptr) == 1, "watching again replaces fn");
  Check((t.sent == std::vector<std::pair<int, bool>>{{7, true}}), "one watch goes to the host");

  Check(page_state::Deliver(7, 2, true, "scroll=40"), "a push of a watched browser is delivered");
  Check(calls.size() == 1 && calls[0].browser == 7 && calls[0].index == 2 &&
            calls[0].state == std::optional<std::string>("scroll=40"),
        "fn reads the pushed state in its turn");
  Check(!Read(7, 3), "an entry never pushed reads as none");
  Check(!page_state::Deliver(8, 0, true, "x"), "no watch for another browser");
  Check(!page_state::Deliver(7, -1, true, "x") && !page_state::Deliver(7, cmux_host::kMaxPageStateEntries, true, "x"),
        "an index past Chromium's entries is dropped");
  Check(page_state::KeptStates() == 1, "and keeps nothing");

  Check(page_state::Deliver(7, 2, false, ""), "a push with none");
  Check(calls.size() == 2 && !calls[1].state, "forgets the entry's older state");
  Check(page_state::Deliver(7, 2, true, std::string(cmux_host::kMaxPageStateBytes + 1, 'x')), "a push over the bound");
  Check(calls.size() == 3 && !calls[2].state, "is kept as none, never cut");

  Check(page_state::Deliver(7, 4, true, "form"), "a push for another entry");
  Check(cmux_shim_tab_page_state_watch(7, nullptr, nullptr) == 0, "a stop answers 0, as the fork's");
  Check(t.sent.size() == 2 && t.sent[1] == std::make_pair(7, false), "the stop goes to the host");
  Check(!Read(7, 4) && page_state::KeptStates() == 0, "a stopped watch keeps nothing");
  Check(cmux_shim_tab_page_state_watch(7, nullptr, nullptr) == 0 && t.sent.size() == 2, "a second stop sends nothing");

  Check(cmux_shim_tab_page_state_watch(5, &StopsItself, nullptr) == 1, "a fn that stops its own watch");
  Check(page_state::Deliver(5, 0, true, "a"), "runs");
  Check(!Read(5, 0), "and its states went with the watch");

  Check(cmux_shim_tab_page_state_watch(9, &OnWatch, nullptr) == 1, "a watch");
  page_state::Deliver(9, 0, true, "kept");
  page_state::BrowserClosed(9);
  Check(!Read(9, 0) && !page_state::Deliver(9, 0, true, "late"), "a closed browser keeps nothing");

  Check(cmux_shim_tab_page_state_watch(11, &OnWatch, nullptr) == 1, "a watch");
  page_state::Deliver(11, 0, true, "kept");
  page_state::Detach();
  Check(!Read(11, 0) && page_state::KeptStates() == 0, "the host's exit ends every watch and state");
  Check(cmux_shim_tab_page_state_watch(11, &OnWatch, nullptr) == 0, "and a watch waits for the next host");

  if (failures) return EXIT_FAILURE;
  std::puts("remote_shim_page_state_test: ok");
  return EXIT_SUCCESS;
}

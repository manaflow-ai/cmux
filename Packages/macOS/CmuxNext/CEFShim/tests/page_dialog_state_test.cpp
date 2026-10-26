// Cases of the shim's page dialog wire form (CEFShim/src/page_dialog_state.h):
// scripts/cmux-next/test-shim-page-dialogs-cpp.sh. A page's alert, confirm,
// prompt and HTTP authentication go to the host (CMUX_SHIM_JS_DIALOG,
// CMUX_SHIM_AUTH, task p01-process-063); each is answered at most once, and
// Chromium's end of a browser's dialogs drops them all.
#include "../src/page_dialog_state.h"

#include <cstdio>
#include <string>

namespace {
int failures = 0;
void Expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

struct FakeCallback {
  int id;
};
}  // namespace

int main() {
  using cmux_shim::AuthDetails;
  using cmux_shim::AuthFlags;
  using cmux_shim::JsDialogDetails;
  using cmux_shim::PageQuestions;

  // CEFShimEvent.swift splits s2 at its first newline: the URL, then the default text as given.
  Expect(JsDialogDetails("https://a.example/page", "") == "https://a.example/page\n", "an alert has no default text");
  Expect(JsDialogDetails("https://a.example/", "two\nlines") == "https://a.example/\ntwo\nlines",
         "a prompt's default text keeps its own newlines after the URL's");
  Expect(JsDialogDetails("", "x") == "\nx", "a frame with no URL still leads with its line");

  // CEFShimEvent.swift splits AUTH's s2 into at most three lines; the realm is the rest.
  Expect(AuthDetails("https://a.example", "basic", "Staff only") == "https://a.example\nbasic\nStaff only",
         "origin, scheme, realm, one per line");
  Expect(AuthDetails("http://a.example", "digest", "") == "http://a.example\ndigest\n", "a challenge with no realm");
  Expect(AuthFlags(true) == 1 && AuthFlags(false) == 0, "bit 0 marks a proxy");

  PageQuestions<FakeCallback> questions;
  const int alert = questions.Add(7, FakeCallback{1});
  const int prompt = questions.Add(7, FakeCallback{2});
  const int other = questions.Add(9, FakeCallback{3});
  Expect(alert > 0 && prompt > alert && other > prompt, "tokens are positive and never reused");
  auto answered = questions.Take(prompt);
  Expect(answered && answered->id == 2, "an answer takes its own question");
  Expect(!questions.Take(prompt), "a second answer finds nothing");
  const auto dropped = questions.TakeAll(7);
  Expect(dropped.size() == 1 && dropped[0].id == 1, "Chromium's reset drops the browser's waiting questions");
  Expect(!questions.Take(alert), "an answer after the reset finds nothing");
  Expect(questions.Take(other).has_value(), "another browser's question stays");

  if (failures == 0) std::printf("page dialog state: all cases pass\n");
  return failures == 0 ? 0 : 1;
}

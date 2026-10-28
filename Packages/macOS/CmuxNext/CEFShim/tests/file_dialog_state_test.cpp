// Cases of the shim's file chooser bookkeeping (CEFShim/src/file_dialog_state.h):
// scripts/cmux-next/test-shim-file-dialog-cpp.sh. A page's <input type=file>
// goes to the host app (CMUX_SHIM_FILE_DIALOG); each request is answered at
// most once, and a closed or crashed browser cancels its pending requests.
#include "../src/file_dialog_state.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {
int failures = 0;
void Expect(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

struct FakeCallback {
  std::vector<std::string>* continued;
  int* cancelled;
};
}  // namespace

int main() {
  using cmux_shim::FileDialogs;
  std::vector<std::string> paths;
  int cancelled = 0;
  FileDialogs<FakeCallback> dialogs;

  const int a = dialogs.Add(7, FakeCallback{&paths, &cancelled});
  const int b = dialogs.Add(7, FakeCallback{&paths, &cancelled});
  const int c = dialogs.Add(9, FakeCallback{&paths, &cancelled});
  Expect(a > 0 && b > a && c > b, "ids are positive and never reused");

  auto taken = dialogs.Take(a);
  Expect(taken.has_value(), "an open request is answered once");
  Expect(!dialogs.Take(a).has_value(), "a second answer finds nothing");
  Expect(!dialogs.Take(12345).has_value(), "an unknown id finds nothing");

  auto dropped = dialogs.TakeAll(7);
  Expect(dropped.size() == 1, "closing browser 7 takes its one pending request");
  Expect(!dialogs.Take(b).has_value(), "and it cannot be answered after");
  Expect(dialogs.Take(c).has_value(), "another browser's request stays");

  Expect(cmux_shim::SplitPaths("") .empty(), "an empty answer is a cancel");
  Expect((cmux_shim::SplitPaths("/a\n/b c\n") == std::vector<std::string>{"/a", "/b c"}), "paths split on newlines");
  Expect((cmux_shim::SplitPaths("relative\n/abs") == std::vector<std::string>{"/abs"}), "relative paths are dropped");
  Expect((cmux_shim::KeepForMode(cmux_shim::SplitPaths("/a\n/b"), /*multiple=*/false) == std::vector<std::string>{"/a"}),
         "a single-file mode keeps one path");
  Expect(cmux_shim::JoinFilters({"image/*", ".png"}) == "image/*\n.png", "accept types join on newlines");

  if (failures == 0) std::printf("file_dialog_state: all cases pass\n");
  return failures == 0 ? 0 : 1;
}

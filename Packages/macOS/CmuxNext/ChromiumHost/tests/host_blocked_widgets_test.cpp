// Checks the Chromium Host's blocked widget handler (src/host_blocked_widgets.h)
// with a fake fork: the handler installs through the
// fork's setter; a shown widget is dismissed once, in a later UI task, and
// logged once as BLOCKED_WIDGET with its browser, kind, class, rect and the
// cmux UI that owns its kind; a move or resize of it neither dismisses nor
// logs again; a widget that hides before its dismissal runs is logged as
// gone and not closed; a dialog that refuses the close (the close returns 1
// and no hide comes) stays, is logged as refused, and its later moves neither
// dismiss nor log it again, while its eventual hide logs it as dismissed; a
// close the fork does not know (0) is logged as close-failed; the fork's
// synchronous hide inside the close is not logged twice; a permission prompt
// is never closed (its Escape is a recorded dismissal), only logged as held
// and, when Chromium ends it, as gone. The window backstop's line hashes the
// title and never prints it.
// Whether the fork blocks every widget is the fork's helper-blocked-widgets
// case (task 176); the counts per row are chromium-host-bench.py --native-ui.
// Run by scripts/cmux-next/tests/chromium-host-blocked-widgets.test.sh.
#include <cstdio>
#include <deque>
#include <functional>
#include <string>
#include <vector>

#include "host_blocked_widgets.h"

namespace {

using namespace cmux_host;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

bool Contains(const std::string& text, const std::string& part) {
  return text.find(part) != std::string::npos;
}

// The fork: its handler, the widgets it closes, and what a close does. A
// close that takes the widget reports it hidden before returning 1, as the
// fork does; a dialog that refuses to cancel returns 1 and stays; a widget
// the fork does not know returns 0.
enum class CloseResult { kTakes, kRefuses, kUnknown };
struct FakeFork {
  BlockedWidgetFn fn = nullptr;
  void* context = nullptr;
  std::vector<int> closed;
  CloseResult result = CloseResult::kTakes;
};
FakeFork* g_fork = nullptr;

int FakeSet(BlockedWidgetFn fn, void* context) {
  g_fork->fn = fn;
  g_fork->context = context;
  return 1;
}

struct Harness {
  FakeFork fork;
  std::deque<std::function<void()>> tasks;
  std::vector<std::string> lines;
  BlockedWidgets widgets{[this](int id) {
                           fork.closed.push_back(id);
                           switch (fork.result) {
                             case CloseResult::kTakes:
                               Show(0, id, 0, 0, "", 0, 0, 0, 0);
                               return 1;
                             case CloseResult::kRefuses:
                               return 1;
                             case CloseResult::kUnknown:
                               break;
                           }
                           return 0;
                         },
                         [this](std::function<void()> task) { tasks.push_back(std::move(task)); },
                         [this](const std::string& line) { lines.push_back(line); }};

  Harness() {
    g_fork = &fork;
    Check(widgets.Install(&FakeSet), "the handler installs through the fork's setter");
    Check(fork.context == &widgets, "the handler's context is the BlockedWidgets");
  }
  void Show(int browser, int id, int kind, int visible, const char* view_class, int x, int y, int w, int h) {
    fork.fn(fork.context, browser, id, kind, visible, view_class, x, y, w, h);
  }
  void RunTasks() {
    while (!tasks.empty()) {
      auto task = std::move(tasks.front());
      tasks.pop_front();
      task();
    }
  }
};

void TestDismissedOnce() {
  Harness h;
  h.Show(7, 11, 0, 1, "JavaScriptTabModalDialogViewViews", 10, 20, 300, 120);
  Check(h.fork.closed.empty(), "no close inside the fork's report (the widget is still showing)");
  Check(h.lines.empty(), "nothing logged before the dismissal runs");
  h.Show(7, 11, 0, 1, "JavaScriptTabModalDialogViewViews", 12, 20, 300, 120);  // moved
  Check(h.tasks.size() == 1, "a move posts no second dismissal");
  h.RunTasks();
  Check(h.fork.closed == std::vector<int>{11}, "the widget is closed once");
  Check(h.lines.size() == 1, "one line for the widget, not one more for the fork's hide");
  if (h.lines.size() == 1) {
    const std::string& line = h.lines[0];
    Check(line.rfind("BLOCKED_WIDGET ", 0) == 0, "the line is a BLOCKED_WIDGET: " + line);
    Check(Contains(line, " browser=7 widget=11 kind=0 "), "browser, widget and kind: " + line);
    Check(Contains(line, " class=JavaScriptTabModalDialogViewViews rect=10,20,300,120 visible=1 "),
          "class and the first rect: " + line);
    Check(Contains(line, " owner=js-dialog action=dismissed"), "owner and action: " + line);
  }
  Check(h.widgets.shown() == 0, "nothing left shown");
}

void TestGoneBeforeDismissal() {
  Harness h;
  h.Show(3, 5, 0, 1, "ChooserBubbleUiViewDelegate", 0, 0, 320, 160);
  h.Show(3, 5, 0, 0, "ChooserBubbleUiViewDelegate", 0, 0, 320, 160);
  h.RunTasks();
  Check(h.fork.closed.empty(), "a widget that hid first is not closed");
  Check(h.lines.size() == 1 && Contains(h.lines[0], " owner=chooser action=gone"),
        "logged once as gone: " + (h.lines.empty() ? std::string() : h.lines[0]));
}

void TestPermissionPromptHeld() {
  Harness h;
  for (const char* view_class : {"PermissionPromptBubbleOneOriginView", "PermissionPromptBubbleTwoOriginView",
                                 "EmbeddedPermissionPromptAskView"}) {
    Check(!DismissesWithEscape(view_class), std::string("no Escape for ") + view_class);
  }
  Check(DismissesWithEscape("JavaScriptTabModalDialogViewViews") && DismissesWithEscape("FindBarView") &&
            DismissesWithEscape(""),
        "every other kind is dismissed with Escape");
  h.Show(3, 5, 0, 1, "PermissionPromptBubbleOneOriginView", 0, 0, 320, 160);
  Check(h.tasks.empty(), "a permission prompt posts no dismissal");
  Check(h.lines.size() == 1 && Contains(h.lines[0], " widget=5 ") &&
            Contains(h.lines[0], " owner=permission-prompt action=held"),
        "it is logged as held when it shows: " + (h.lines.empty() ? std::string() : h.lines[0]));
  h.Show(3, 5, 0, 1, "PermissionPromptBubbleOneOriginView", 4, 0, 320, 160);  // moved
  h.RunTasks();
  Check(h.fork.closed.empty(), "it is never closed through the Escape path, moved or not");
  Check(h.lines.size() == 1 && h.widgets.shown() == 1, "a move logs nothing and it stays held");
  h.Show(3, 5, 0, 0, "PermissionPromptBubbleOneOriginView", 4, 0, 320, 160);  // Chromium ended it
  Check(h.lines.size() == 2 && Contains(h.lines[1], " widget=5 ") && Contains(h.lines[1], " action=gone"),
        "Chromium's end of it logs it as gone: " + (h.lines.size() < 2 ? std::string() : h.lines[1]));
  Check(h.fork.closed.empty() && h.widgets.shown() == 0, "still never closed, and it is gone");
}

void TestRefused() {
  Harness h;
  h.fork.result = CloseResult::kRefuses;
  h.Show(0, 9, 0, 1, "SomeUnknownDialogView", 100, 100, 50, 40);
  h.RunTasks();
  Check(h.fork.closed == std::vector<int>{9}, "the refusing dialog is closed once");
  Check(h.lines.size() == 1 && Contains(h.lines[0], " browser=0 ") &&
            Contains(h.lines[0], " owner=none action=refused"),
        "a close that returns 1 with no hide is logged as refused, not dismissed: " +
            (h.lines.empty() ? std::string() : h.lines[0]));
  Check(h.widgets.shown() == 1, "a refused widget stays shown");
  h.Show(0, 9, 0, 1, "SomeUnknownDialogView", 120, 100, 50, 40);  // moved
  h.Show(0, 9, 0, 1, "SomeUnknownDialogView", 120, 100, 60, 40);  // resized
  Check(h.tasks.empty(), "its later moves post no second dismissal");
  h.RunTasks();
  Check(h.fork.closed.size() == 1, "its later moves do not close it again");
  Check(h.lines.size() == 1, "its later moves log nothing");
  h.Show(0, 9, 0, 0, "SomeUnknownDialogView", 120, 100, 60, 40);
  Check(h.lines.size() == 2 && Contains(h.lines[1], " widget=9 ") && Contains(h.lines[1], " action=dismissed"),
        "its hide at last logs it as dismissed: " + (h.lines.size() < 2 ? std::string() : h.lines[1]));
  Check(h.widgets.shown() == 0, "and it is gone");
  h.Show(0, 9, 0, 0, "SomeUnknownDialogView", 120, 100, 60, 40);
  Check(h.lines.size() == 2, "a second hide logs nothing");
}

void TestCloseFailed() {
  Harness h;
  h.fork.result = CloseResult::kUnknown;
  h.Show(2, 6, 0, 1, "FindBarView", 0, 0, 10, 10);
  h.RunTasks();
  Check(h.lines.size() == 1 && Contains(h.lines[0], " owner=find action=close-failed"),
        "a close the fork does not know is logged as close-failed: " + (h.lines.empty() ? std::string() : h.lines[0]));
  h.Show(2, 6, 0, 1, "FindBarView", 5, 0, 10, 10);
  h.RunTasks();
  Check(h.fork.closed.size() == 1 && h.lines.size() == 1, "a later move neither closes nor logs it again");
  h.Show(2, 6, 0, 0, "FindBarView", 5, 0, 10, 10);
  Check(h.lines.size() == 1 && h.widgets.shown() == 0, "its hide is not logged again");
}

void TestPagePopupAndOwners() {
  Harness h;
  h.Show(4, 1, 3, 1, "", 0, 0, 10, 10);
  h.Show(4, 2, 0, 1, "FindBarView", 0, 0, 10, 10);
  h.Show(4, 3, 0, 1, "DesktopMediaPickerDialogView", 0, 0, 10, 10);
  h.Show(4, 4, 0, 1, "LoginView", 0, 0, 10, 10);
  h.Show(4, 5, 0, 1, "Bad class name\nwith=signs", 0, 0, 10, 10);
  h.RunTasks();
  Check(h.lines.size() == 5, "five widgets, five lines");
  if (h.lines.size() == 5) {
    Check(Contains(h.lines[0], " kind=3 class=- ") && Contains(h.lines[0], " owner=none "),
          "a page popup has no class: " + h.lines[0]);
    Check(Contains(h.lines[1], " owner=find action=dismissed"),
          "the find bar is find's, and dismissed: Chromium's own find does not open cmux's: " + h.lines[1]);
    Check(Contains(h.lines[2], " owner=chooser "), "the screen share picker is a chooser's: " + h.lines[2]);
    Check(Contains(h.lines[3], " owner=js-dialog "), "HTTP auth is 063's: " + h.lines[3]);
    Check(Contains(h.lines[4], " class=Bad_class_name_with_signs "), "a class name is one token: " + h.lines[4]);
  }
}

void TestNoSetter() {
  BlockedWidgets widgets([](int) { return 1; }, [](std::function<void()>) {}, [](const std::string&) {});
  Check(!widgets.Install(nullptr), "no setter (a fork below API 31): not installed");
  Check(!widgets.Install([](BlockedWidgetFn, void*) { return 0; }), "a refused setter: not installed");
}

void TestUnexpectedWindowLine() {
  const std::string line = UnexpectedWindowLine("NSPanel", "secret page text", false);
  Check(line == "UNEXPECTED_WINDOW class=NSPanel title=" + std::string([] {
          char hash[16];
          std::snprintf(hash, sizeof hash, "%08x", TitleHash("secret page text"));
          return std::string(hash);
        }()) + " action=ordered-out",
        "the window line: " + line);
  Check(!Contains(line, "secret"), "the title itself is never logged");
  Check(TitleHash("") == 2166136261u && TitleHash("a") == 0xe40c292cu, "FNV-1a 32");
  Check(Contains(UnexpectedWindowLine("NSWindow", "", true), " action=sheet-ended"), "a sheet is ended");
}

}  // namespace

int main() {
  TestDismissedOnce();
  TestGoneBeforeDismissal();
  TestPermissionPromptHeld();
  TestRefused();
  TestCloseFailed();
  TestPagePopupAndOwners();
  TestNoSetter();
  TestUnexpectedWindowLine();
  if (failures) return 1;
  std::printf("host_blocked_widgets_test: ok\n");
  return 0;
}

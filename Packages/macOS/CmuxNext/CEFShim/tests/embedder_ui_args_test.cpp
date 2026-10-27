// Checks the fork API 31 argument conversions (CEFShim/src/embedder_ui_args.h,
// scripts/cmux-next/test-shim-embedder-ui-args-cpp.sh): device chooser rows,
// the screen-share answer's id and NUL-terminated restore entries.
#include <climits>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include "../src/embedder_ui_args.h"

#ifdef CMUX_CHECK_FORK_HEADER
// With a fork checkout (CMUX_CEF_FORK, see the script): the copies have
// include/cef_cmux.h's layouts.
#include <cstddef>

#include "include/cef_cmux.h"

#define SAME(T, U)                                   \
  static_assert(sizeof(T) == sizeof(U), #T " size"); \
  static_assert(alignof(T) == alignof(U), #T " alignment")
#define FIELD(T, U, f) static_assert(offsetof(T, f) == offsetof(U, f), #T "." #f)
SAME(cmux_shim::ForkColorChooserHandler, cmux_color_chooser_handler_t);
FIELD(cmux_shim::ForkColorChooserHandler, cmux_color_chooser_handler_t, open);
FIELD(cmux_shim::ForkColorChooserHandler, cmux_color_chooser_handler_t, set_color);
FIELD(cmux_shim::ForkColorChooserHandler, cmux_color_chooser_handler_t, end);
FIELD(cmux_shim::ForkColorChooserHandler, cmux_color_chooser_handler_t, context);
SAME(cmux_shim::ForkDeviceChooserHandler, cmux_device_chooser_handler_t);
FIELD(cmux_shim::ForkDeviceChooserHandler, cmux_device_chooser_handler_t, update);
FIELD(cmux_shim::ForkDeviceChooserHandler, cmux_device_chooser_handler_t, close);
FIELD(cmux_shim::ForkDeviceChooserHandler, cmux_device_chooser_handler_t, context);
SAME(cmux_shim::ForkDesktopMediaHandler, cmux_desktop_media_handler_t);
FIELD(cmux_shim::ForkDesktopMediaHandler, cmux_desktop_media_handler_t, open);
FIELD(cmux_shim::ForkDesktopMediaHandler, cmux_desktop_media_handler_t, close);
FIELD(cmux_shim::ForkDesktopMediaHandler, cmux_desktop_media_handler_t, context);
SAME(cmux_shim::ForkLockHandler, cmux_lock_handler_t);
FIELD(cmux_shim::ForkLockHandler, cmux_lock_handler_t, pointer_lock_requested);
FIELD(cmux_shim::ForkLockHandler, cmux_lock_handler_t, pointer_unlocked);
FIELD(cmux_shim::ForkLockHandler, cmux_lock_handler_t, keyboard_lock_requested);
FIELD(cmux_shim::ForkLockHandler, cmux_lock_handler_t, keyboard_unlocked);
FIELD(cmux_shim::ForkLockHandler, cmux_lock_handler_t, context);
FIELD(cmux_shim::ForkColorChooserHead, cmux_color_chooser_t, token);
FIELD(cmux_shim::ForkColorChooserHead, cmux_color_chooser_t, color);
FIELD(cmux_shim::ForkTokenHead, cmux_device_chooser_t, token);
FIELD(cmux_shim::ForkTokenHead, cmux_desktop_media_request_t, token);
SAME(cmux_shim::ForkRestoreEntry, cmux_restore_entry_t);
FIELD(cmux_shim::ForkRestoreEntry, cmux_restore_entry_t, url);
FIELD(cmux_shim::ForkRestoreEntry, cmux_restore_entry_t, title);
FIELD(cmux_shim::ForkRestoreEntry, cmux_restore_entry_t, page_state);
static_assert(cmux_shim::kDesktopMediaTab == CMUX_DESKTOP_MEDIA_TAB, "CMUX_DESKTOP_MEDIA_TAB");
#endif

using cmux_shim::DesktopMediaAnswerId;
using cmux_shim::DeviceChoiceIndices;
using cmux_shim::RestoreEntries;

static int g_cases = 0;
static int g_failures = 0;

static void Expect(bool ok, const char* what) {
  ++g_cases;
  if (!ok) {
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
  }
}

static void DeviceChoices() {
  std::vector<int> out = {7};
  Expect(DeviceChoiceIndices(nullptr, 0, &out) && out.empty(), "no rows (the scanning prompt's Allow) is valid");
  const cmux_shim_device_choice rows[] = {{0}, {3}, {INT_MAX}};
  Expect(DeviceChoiceIndices(rows, 3, &out) && out == std::vector<int>({0, 3, INT_MAX}), "rows keep order and value");
  const cmux_shim_device_choice negative[] = {{1}, {-1}};
  Expect(!DeviceChoiceIndices(negative, 2, &out), "a negative index is refused");
  const cmux_shim_device_choice huge[] = {{static_cast<int64_t>(INT_MAX) + 1}};
  Expect(!DeviceChoiceIndices(huge, 1, &out), "an index past INT_MAX is refused");
  Expect(!DeviceChoiceIndices(nullptr, 1, &out), "NULL rows with a count are refused");
  Expect(!DeviceChoiceIndices(rows, -1, &out), "a negative count is refused");
}

static void DesktopMediaIds() {
  Expect(DesktopMediaAnswerId(1 << 0, 69733378, 9) == 69733378, "a screen answer sends the display id");
  Expect(DesktopMediaAnswerId(1 << 1, 4242, 9) == 4242, "a window answer sends the window id");
  Expect(DesktopMediaAnswerId(1 << 2, 4242, 9) == 9, "a tab answer sends the tab's browser id");
  Expect(DesktopMediaAnswerId(1 << 3, 0, 0) == 0, "the current tab needs no id");
  Expect(DesktopMediaAnswerId(0, 0, 0) == 0, "a cancel sends 0");
}

static void Restore() {
  // Bytes with explicit lengths and no terminator where the length ends.
  const char url_bytes[] = "https://a.test/one#tail";
  const char title_bytes[] = "One!";
  const char state_bytes[] = "AAAA====";
  const cmux_shim_restore_entry entries[] = {
      {url_bytes, 15, title_bytes, 3, state_bytes, 4},
      {"https://b.test/", 15, nullptr, 0, nullptr, 0},
      {"https://c.test/", 15, "", 0, "", 0},
  };
  const RestoreEntries copies(entries, 3);
  Expect(copies.count() == 3, "every entry is copied");
  const cmux_shim::ForkRestoreEntry* fork = copies.data();
  Expect(std::strcmp(fork[0].url, "https://a.test/") == 0, "the url ends at its length");
  Expect(std::strcmp(fork[0].title, "One") == 0, "the title ends at its length");
  Expect(fork[0].page_state && std::strcmp(fork[0].page_state, "AAAA") == 0, "the page state ends at its length");
  Expect(fork[1].title && fork[1].title[0] == '\0', "a NULL title is empty");
  Expect(fork[1].page_state == nullptr, "a NULL page state is none");
  Expect(fork[2].page_state == nullptr, "an empty page state is none");
  Expect(fork[0].url != url_bytes, "the fork reads the shim's copies, not the caller's bytes");
  Expect(RestoreEntries(nullptr, 2).count() == 0, "NULL entries copy nothing");
  Expect(RestoreEntries(entries, 0).count() == 0, "no entries copy nothing");
  // Many entries: no copy moves while later ones are added.
  std::vector<std::string> urls;
  std::vector<cmux_shim_restore_entry> many;
  for (int i = 0; i < 200; ++i) urls.push_back("https://many.test/" + std::to_string(i) + std::string(40, 'x'));
  for (const std::string& u : urls) many.push_back({u.data(), u.size(), u.data(), u.size(), u.data(), u.size()});
  const RestoreEntries big(many.data(), static_cast<int>(many.size()));
  bool same = big.count() == 200;
  for (int i = 0; same && i < 200; ++i) {
    same = urls[static_cast<size_t>(i)] == big.data()[i].url && urls[static_cast<size_t>(i)] == big.data()[i].title &&
           urls[static_cast<size_t>(i)] == big.data()[i].page_state;
  }
  Expect(same, "200 entries keep their strings");
}

// A fake fork setter: like the fork, it ends the old handler's open request
// (its `close`) inside the call when a handler was set, and refuses a handler
// while `refuse` is set.
using cmux_shim::AppHandler;
using cmux_shim::ForkDesktopMediaHandler;
using cmux_shim::SetAppHandler;
using MediaFn = void (*)(void* context, int event, int browser_id, int64_t token, const void* data);

static AppHandler<MediaFn> g_app;
static bool g_fork_has_handler = false;
static bool g_refuse = false;
static int g_fork_sets = 0;
static std::vector<std::string> g_seen;

static void ForkClose(void*, int64_t token) {
  if (g_app.fn) g_app.fn(g_app.context, 1, 0, token, nullptr);
}

static int FakeForkSet(const ForkDesktopMediaHandler* handler) {
  ++g_fork_sets;
  if (handler && g_refuse) return 0;
  if (g_fork_has_handler) ForkClose(nullptr, 77);  // the old handler's request ends
  g_fork_has_handler = handler != nullptr;
  return 1;
}

static void OldFn(void* context, int event, int, int64_t token, const void*) {
  g_seen.push_back(std::string(static_cast<const char*>(context)) + " event " + std::to_string(event) + " token " +
                   std::to_string(token));
}
static void NewFn(void* context, int event, int, int64_t token, const void*) { OldFn(context, event, 0, token, nullptr); }

static void Handlers() {
  static const ForkDesktopMediaHandler handler = {sizeof(ForkDesktopMediaHandler), nullptr, &ForkClose, nullptr};
  static char old_ctx[] = "old";
  static char new_ctx[] = "new";
  Expect(SetAppHandler<MediaFn, ForkDesktopMediaHandler>(nullptr, &handler, g_app, &OldFn, old_ctx) == 0,
         "a fork without the call returns 0");
  Expect(SetAppHandler(&FakeForkSet, &handler, g_app, &OldFn, static_cast<void*>(old_ctx)) == 1 &&
             g_app.fn == &OldFn && g_app.context == old_ctx,
         "the first handler is set in the fork and kept for the app");
  Expect(g_seen.empty(), "setting the first handler ends nothing");
  Expect(SetAppHandler(&FakeForkSet, &handler, g_app, &NewFn, static_cast<void*>(new_ctx)) == 1 &&
             g_app.fn == &NewFn,
         "a second handler replaces the first");
  Expect(g_seen.size() == 1 && g_seen[0] == "old event 1 token 77",
         "the replaced handler's open request ends at the old fn with its context");
  g_refuse = true;
  Expect(SetAppHandler(&FakeForkSet, &handler, g_app, &OldFn, static_cast<void*>(old_ctx)) == 0 &&
             g_app.fn == &NewFn && g_app.context == new_ctx,
         "a handler the fork refuses keeps the app's current one");
  g_refuse = false;
  g_seen.clear();
  Expect(SetAppHandler(&FakeForkSet, &handler, g_app, static_cast<MediaFn>(nullptr), nullptr) == 1 &&
             g_app.fn == nullptr && !g_fork_has_handler,
         "fn NULL removes the fork's handler and the app's");
  Expect(g_seen.size() == 1 && g_seen[0] == "new event 1 token 77",
         "the removed handler's open request ends at its fn before it is forgotten");
}

int main() {
  Handlers();
  DeviceChoices();
  DesktopMediaIds();
  Restore();
  if (g_failures) {
    std::cerr << g_failures << " of " << g_cases << " failed\n";
    return 1;
  }
  std::cout << "embedder_ui_args: " << g_cases << " passed\n";
  return 0;
}

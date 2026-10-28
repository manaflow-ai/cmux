// Checks the Chromium Host's chooser handlers
// (src/host_choosers.h): the payload encoders and decoders alone, then end to
// end with the real dispatcher (src/host_dispatch.mm) and a fake shim on one
// end of a socket pair and the real remote shim (client/, loaded as the
// shared library cmux loads) on the other, every call made through the remote
// shim's exports as cmux's Swift code makes it:
//   - a handler cmux sets before the host starts is installed in the host's
//     shim once initialize returned; removing it removes the host's;
//   - an OPEN or UPDATE reaches cmux's fn with the fork's struct rebuilt
//     (suggestions, rows, texts) and cmux's minted browser id; SET_COLOR and
//     END follow; an END of a token cmux no longer has open is dropped;
//   - cmux's answers reach the host's shim, a shared tab's id mapped to
//     Chromium's; the pushes never reach cmux's event fn;
//   - removing a handler, or the host's end, ends cmux's open requests at its
//     fn; a malformed setter op ends the host.
// Built and run by scripts/cmux-next/tests/chromium-host-dispatch.test.sh.
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_choosers.h"
#include "host_dispatch.h"
#include "remote_shim_runtime.h"

#include "generated/host_dispatch.inc"

namespace {

using cmux_host::HostContext;
using cmux_host::choosers::ColorChooserData;
using cmux_host::choosers::DesktopMediaData;
using cmux_host::choosers::DeviceChooserData;
using cmux_host::choosers::ForkColorChooser;
using cmux_host::choosers::ForkDesktopMediaRequest;
using cmux_host::choosers::ForkDeviceChooser;
using cmux_host::choosers::ForkDeviceOption;
using cmux_host::control::Channel;
using cmux_host::control::End;
using cmux_host::control::Message;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

// The test thread is both processes' main thread: tasks from both channels run here, in order.
std::mutex queue_mutex;
std::deque<std::function<void()>> queue;

void PostTask(std::function<void()> task) {
  std::lock_guard<std::mutex> lock(queue_mutex);
  queue.push_back(std::move(task));
}

void PostMain(void*, cmux_remote_main_task_fn run, void* task) {
  PostTask([run, task] { run(task); });
}

bool PumpUntil(const std::function<bool()>& done) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!done()) {
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      tasks.swap(queue);
    }
    for (std::function<void()>& task : tasks) task();
    if (std::chrono::steady_clock::now() > deadline) return false;
    if (tasks.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  return true;
}

// Runs every task already posted and those they post, for a short while: for "nothing happens" checks.
void PumpBriefly() {
  const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
  PumpUntil([until] { return std::chrono::steady_clock::now() > until; });
}

// The remote shim's exports, as cmux binds them (CEFShimLibrary).
struct Client {
  decltype(&cmux_remote_shim_configure) configure;
  decltype(&cmux_remote_shim_attach) attach;
  decltype(&cmux_remote_shim_detach) detach;
  decltype(&cmux_shim_initialize) initialize;
  decltype(&cmux_shim_create_window) create_window;
  decltype(&cmux_shim_set_color_chooser_handler) set_color;
  decltype(&cmux_shim_set_device_chooser_handler) set_device;
  decltype(&cmux_shim_set_desktop_media_handler) set_media;
  decltype(&cmux_shim_color_chooser_choose) color_choose;
  decltype(&cmux_shim_color_chooser_end) color_end;
  decltype(&cmux_shim_device_chooser_answer) device_answer;
  decltype(&cmux_shim_desktop_media_answer) media_answer;
};

template <typename T>
void Bind(void* library, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(library, name));
  if (*out == nullptr) {
    std::fprintf(stderr, "FAIL: the remote shim has no %s\n", name);
    std::exit(EXIT_FAILURE);
  }
}

Client LoadClient() {
  void* library = dlopen(CMUX_REMOTE_SHIM_PATH, RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    std::fprintf(stderr, "FAIL: %s\n", dlerror());
    std::exit(EXIT_FAILURE);
  }
  Client c{};
  Bind(library, "cmux_remote_shim_configure", &c.configure);
  Bind(library, "cmux_remote_shim_attach", &c.attach);
  Bind(library, "cmux_remote_shim_detach", &c.detach);
  Bind(library, "cmux_shim_initialize", &c.initialize);
  Bind(library, "cmux_shim_create_window", &c.create_window);
  Bind(library, "cmux_shim_set_color_chooser_handler", &c.set_color);
  Bind(library, "cmux_shim_set_device_chooser_handler", &c.set_device);
  Bind(library, "cmux_shim_set_desktop_media_handler", &c.set_media);
  Bind(library, "cmux_shim_color_chooser_choose", &c.color_choose);
  Bind(library, "cmux_shim_color_chooser_end", &c.color_end);
  Bind(library, "cmux_shim_device_chooser_answer", &c.device_answer);
  Bind(library, "cmux_shim_desktop_media_answer", &c.media_answer);
  return c;
}

Client client;

using ColorFn = void (*)(void*, int, int, int64_t, unsigned int, const void*);
using ChooserFn = void (*)(void*, int, int, int64_t, const void*);

// The host's fake shim: the handlers the host installed and the answers it got.
struct Shim {
  HostContext* host = nullptr;
  int next_browser = 3;
  ColorFn color = nullptr;
  ChooserFn device = nullptr;
  ChooserFn media = nullptr;
  void* color_ctx = nullptr;
  void* device_ctx = nullptr;
  void* media_ctx = nullptr;
  int set_calls = 0;
  bool fork_has_choosers = true;
  std::vector<std::pair<int64_t, unsigned int>> chosen;
  std::vector<int64_t> color_ended;
  std::vector<std::tuple<int64_t, int, std::vector<int64_t>>> device_answers;
  std::vector<std::tuple<int64_t, int, int64_t, int, int>> media_answers;
} shim;

}  // namespace

extern "C" {
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  const int browser = shim.next_browser++;
  HostContext::OnShimEvent(shim.host, CMUX_SHIM_AFTER_CREATED, browser, request, 11, 0, "", "");
  return 1;
}
int cmux_shim_set_color_chooser_handler(ColorFn fn, void* context) {
  ++shim.set_calls;
  if (!shim.fork_has_choosers) return 0;
  shim.color = fn;
  shim.color_ctx = context;
  return 1;
}
int cmux_shim_set_device_chooser_handler(ChooserFn fn, void* context) {
  ++shim.set_calls;
  if (!shim.fork_has_choosers) return 0;
  shim.device = fn;
  shim.device_ctx = context;
  return 1;
}
int cmux_shim_set_desktop_media_handler(ChooserFn fn, void* context) {
  ++shim.set_calls;
  if (!shim.fork_has_choosers) return 0;
  shim.media = fn;
  shim.media_ctx = context;
  return 1;
}
int cmux_shim_color_chooser_choose(int64_t token, unsigned int color) {
  shim.chosen.emplace_back(token, color);
  return 1;
}
int cmux_shim_color_chooser_end(int64_t token) {
  shim.color_ended.push_back(token);
  return 1;
}
int cmux_shim_device_chooser_answer(int64_t token, int action, const cmux_shim_device_choice* choices, int count) {
  std::vector<int64_t> rows;
  for (int i = 0; i < count; ++i) rows.push_back(choices[i].index);
  shim.device_answers.emplace_back(token, action, rows);
  return 1;
}
int cmux_shim_desktop_media_answer(int64_t token, int source_type, int64_t native_id, int tab_browser_id, int audio) {
  shim.media_answers.emplace_back(token, source_type, native_id, tab_browser_id, audio);
  return 1;
}
}

namespace {

// What cmux's handler fns saw, copied out of the structs during the call.
struct Seen {
  int handler = 0;  // 0 color, 1 device, 2 media
  int event = 0;
  int browser = 0;
  int64_t token = 0;
  unsigned int color = 0;
  bool data = false;
  std::vector<std::pair<uint32_t, std::string>> suggestions;
  std::vector<std::string> texts;  // device: origin, title, no_options_text, ok_label; media: app_name
  std::vector<int> flags;          // device: the eight flags; media: source_types, preferred, audio
  std::vector<std::tuple<std::string, int, int, int>> rows;
};
std::vector<Seen> seen;
int other_ctx = 0;

Seen Make(int handler, int event, int browser, int64_t token, unsigned int color, const void* data) {
  Seen s;
  s.handler = handler;
  s.event = event;
  s.browser = browser;
  s.token = token;
  s.color = color;
  s.data = data != nullptr;
  return s;
}
std::vector<void*> seen_ctx;

void OnColor(void* ctx, int event, int browser, int64_t token, unsigned int color, const void* data) {
  Seen s = Make(0, event, browser, token, color, data);
  if (const auto* c = static_cast<const ForkColorChooser*>(data)) {
    Check(c->size == static_cast<int>(sizeof(ForkColorChooser)) && c->token == token && c->color == color,
          "the color chooser struct carries its size, token and color");
    for (int i = 0; i < c->suggestion_count; ++i) s.suggestions.emplace_back(c->suggestion_colors[i], c->suggestion_labels[i]);
  }
  seen.push_back(s);
  seen_ctx.push_back(ctx);
}

void OnDevice(void* ctx, int event, int browser, int64_t token, const void* data) {
  Seen s = Make(1, event, browser, token, 0, data);
  if (const auto* d = static_cast<const ForkDeviceChooser*>(data)) {
    Check(d->size == static_cast<int>(sizeof(ForkDeviceChooser)) && d->token == token, "the device struct's token");
    s.texts = {d->origin, d->title, d->no_options_text, d->ok_label};
    s.flags = {d->show_signal_strength, d->show_rescan, d->allow_multiple, d->initialized, d->refreshing,
               d->adapter_enabled, d->adapter_authorized, d->both_buttons_always_enabled};
    for (int i = 0; i < d->option_count; ++i) {
      const ForkDeviceOption& o = d->options[i];
      s.rows.emplace_back(o.name, o.signal_strength, o.connected, o.paired);
    }
  }
  seen.push_back(s);
  seen_ctx.push_back(ctx);
}

void OnMedia(void* ctx, int event, int browser, int64_t token, const void* data) {
  Seen s = Make(2, event, browser, token, 0, data);
  if (const auto* r = static_cast<const ForkDesktopMediaRequest*>(data)) {
    s.texts = {r->app_name};
    s.flags = {r->source_types, r->preferred_source, r->request_audio};
  }
  seen.push_back(s);
  seen_ctx.push_back(ctx);
}

bool initialized = false;
bool ready = false;
int ended = -1;
std::vector<std::pair<int, int>> events_seen;  // (kind, browser) of what reached cmux's event fn

struct Delegate : cmux_host::HostDelegate {
  std::function<void()> resume;
  bool resumed = false;
  std::vector<std::string> bad;
  void Initialize(cmux_host::InitializeRequest) override {
    PostTask([this] {
      resume();
      resumed = true;
    });
  }
  void Quit() override {}
  void BrowserClosed() override {}
  void BadMessage(const std::string& what) override { bad.push_back(what); }
};

struct Views : cmux_host::PageViews {
  int view = 0;
  void* Open(uint64_t) override { return &view; }
  void Close(uint64_t) override {}
  void Place(uint64_t, const cmux_host::PageGeometry&) override {}
};

void OnEvent(void*, int kind, int browser, int, int64_t, int64_t, const char*, const char*) {
  events_seen.emplace_back(kind, browser);
}
void OnReady(void*) { ready = true; }
void OnEnded(void*, int reason) { ended = reason; }

// One host and its attached remote shim.
struct World {
  Delegate delegate;
  Views views;
  std::unique_ptr<Channel> channel;
  HostContext host{[this](const Message& m) { return channel && channel->Send(m); }, delegate, views, nullptr};
  bool attached = true;

  World() {
    const bool fork = shim.fork_has_choosers;
    shim = Shim();
    shim.fork_has_choosers = fork;
    shim.host = &host;
    ready = false;
    ended = -1;
    seen.clear();
    seen_ctx.clear();
    events_seen.clear();
    delegate.resume = [this] { host.Resume(); };
    int pair[2];
    Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
    channel = std::make_unique<Channel>(
        pair[1], &PostTask, [this](std::vector<Message> batch) { host.OnMessages(std::move(batch)); },
        [](End) {});
    host.Attach();
    Check(client.attach(pair[0], nullptr, nullptr) == 1, "the remote shim attaches");
    if (!initialized) {
      const char* switches[] = {nullptr};
      Check(client.initialize("/fw", "/app", "/helper", "/root", nullptr, 0, nullptr, nullptr, switches, nullptr,
                              nullptr, &OnEvent, nullptr) == 1,
            "initialize is sent");
      initialized = true;
    }
    Check(PumpUntil([this] { return ready && delegate.resumed; }), "the hellos and initialize go through");
  }

  ~World() {
    Detach();
    channel->Close();
    channel.reset();
  }

  void Detach() {
    if (!attached) return;
    attached = false;
    client.detach();
  }

  int CreateWindow() {
    Check(client.create_window(++requests, nullptr, 800, 600, "about:blank", nullptr) == 1, "create_window is sent");
    const size_t before = events_seen.size();
    int created = 0;
    Check(PumpUntil([&] {
            for (size_t i = before; i < events_seen.size(); ++i) {
              if (events_seen[i].first == CMUX_SHIM_AFTER_CREATED) created = events_seen[i].second;
            }
            return created != 0;
          }),
          "AFTER_CREATED reaches cmux");
    Check(created >= (1 << 20), "the tab has cmux's minted id");
    return created;
  }
  int requests = 41;

  // Runs until cmux's fns saw `count` calls in all.
  void PumpUntilSeen(size_t count, const std::string& what) {
    Check(PumpUntil([count] { return seen.size() >= count; }), what);
  }
};

// The encoders and decoders alone: a round trip keeps every field; an
// unreadable struct goes as an empty one; strings and lists stay in bounds.
void PayloadsRoundTrip() {
  const uint32_t colors[] = {0xFFFF0000u, 0xFF00FF00u};
  const char* labels[] = {"red", nullptr};
  ForkColorChooser chooser{static_cast<int>(sizeof(ForkColorChooser)), 7, 0xFF112233u, colors, labels, 2};
  std::string payload;
  Check(cmux_host::choosers::EncodeColorChooser(&chooser, &payload), "a color chooser encodes");
  auto color = ColorChooserData::Decode(payload, 7, 0xFF112233u);
  Check(color && color->fork()->suggestion_count == 2 && color->fork()->suggestion_colors[1] == 0xFF00FF00u &&
            std::string(color->fork()->suggestion_labels[0]) == "red" &&
            std::string(color->fork()->suggestion_labels[1]).empty() && color->fork()->token == 7,
        "a color chooser's suggestions round trip (a NULL label as \"\")");

  ForkDeviceOption options[] = {{"Keyboard", 3, 0, 1}, {"Mouse", -1, 1, 0}};
  ForkDeviceChooser device{static_cast<int>(sizeof(ForkDeviceChooser)), 9, "https://a.test", "a.test wants to pair",
                           "No devices", "Pair", 1, 1, 0, 1, 0, 1, 1, 0, options, 2};
  Check(cmux_host::choosers::EncodeDeviceChooser(&device, &payload), "a device chooser encodes");
  auto rows = DeviceChooserData::Decode(payload, 9);
  Check(rows && rows->fork()->option_count == 2 && std::string(rows->fork()->options[1].name) == "Mouse" &&
            rows->fork()->options[0].signal_strength == 3 && rows->fork()->options[1].connected == 1 &&
            std::string(rows->fork()->title) == "a.test wants to pair" && rows->fork()->show_rescan == 1 &&
            rows->fork()->adapter_authorized == 1 && rows->fork()->both_buttons_always_enabled == 0,
        "a device chooser's texts, flags and rows round trip");

  ForkDesktopMediaRequest media{static_cast<int>(sizeof(ForkDesktopMediaRequest)), 5, "a.test", 7, 2, 1};
  Check(cmux_host::choosers::EncodeDesktopMedia(&media, &payload), "a media request encodes");
  auto request = DesktopMediaData::Decode(payload, 5);
  Check(request && std::string(request->fork()->app_name) == "a.test" && request->fork()->source_types == 7 &&
            request->fork()->preferred_source == 2 && request->fork()->request_audio == 1,
        "a media request round trips");

  // An older (smaller) struct, or none, goes as an empty one.
  ForkDeviceChooser old = device;
  old.size = 8;
  Check(cmux_host::choosers::EncodeDeviceChooser(&old, &payload), "an older device struct encodes");
  rows = DeviceChooserData::Decode(payload, 9);
  Check(rows && rows->fork()->option_count == 0 && std::string(rows->fork()->title).empty(),
        "an older device struct goes as an empty one");
  Check(cmux_host::choosers::EncodeColorChooser(nullptr, &payload) && ColorChooserData::Decode(payload, 1, 0),
        "no color struct goes as one with no suggestions");

  // A long string is cut at a UTF-8 boundary; a list stops where the payload is full, as a prefix.
  std::string long_name(cmux_host::choosers::kMaxText - 1, 'a');
  long_name += "\xC3\xA9tail";  // é straddles the cut
  std::vector<ForkDeviceOption> many(400, ForkDeviceOption{long_name.c_str(), 0, 0, 0});
  device.options = many.data();
  device.option_count = static_cast<int>(many.size());
  Check(cmux_host::choosers::EncodeDeviceChooser(&device, &payload), "a long device list encodes");
  rows = DeviceChooserData::Decode(payload, 9);
  Check(rows && rows->fork()->option_count > 0 && rows->fork()->option_count < 400 &&
            std::string(rows->fork()->options[0].name) == std::string(cmux_host::choosers::kMaxText - 1, 'a') &&
            payload.size() <= cmux_host::choosers::kMaxPayload + 4096,
        "names cut before a split character, rows cut to the payload bound");

  Check(!ColorChooserData::Decode("garbage", 1, 0) && !DeviceChooserData::Decode("", 1) &&
            !DesktopMediaData::Decode(std::string("\x01\x00\x04\x00", 4), 1),
        "a payload that is not the encoder's does not decode");
}

// Set before the host starts: installed once initialize returned. A fork that
// refuses keeps Chromium's own; cmux removing its fn removes the host's.
void InstalledAtInitializeAndRemoved() {
  client.set_color(&OnColor, &other_ctx);
  {
    World w;
    Check(PumpUntil([] { return shim.color != nullptr; }), "the color handler set before attach is installed");
    Check(w.host.chooser_installed(cmux_host::choosers::kColor) &&
              !w.host.chooser_installed(cmux_host::choosers::kDevice),
          "only the handler cmux set is installed");
    client.set_color(nullptr, nullptr);
    Check(PumpUntil([] { return shim.color == nullptr; }), "removing cmux's handler removes the host's");
    Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
  }
  shim.fork_has_choosers = false;
  client.set_device(&OnDevice, nullptr);
  {
    World w;
    PumpUntil([] { return shim.set_calls > 0; });
    Check(shim.set_calls == 1 && !w.host.chooser_installed(cmux_host::choosers::kDevice),
          "a fork without the handler leaves it uninstalled");
    client.set_device(nullptr, nullptr);
    PumpBriefly();
  }
  shim.fork_has_choosers = true;
}

// The color chooser end to end: OPEN with the suggestions and cmux's browser
// id, live answers, SET_COLOR and END; a second END and the events stay out
// of cmux's event fn.
void ColorChooserEndToEnd() {
  World w;
  const int tab = w.CreateWindow();
  client.set_color(&OnColor, &other_ctx);
  Check(PumpUntil([] { return shim.color != nullptr; }), "the color handler is installed");
  const uint32_t colors[] = {0xFFABCDEFu};
  const char* labels[] = {"brand"};
  ForkColorChooser chooser{static_cast<int>(sizeof(ForkColorChooser)), 41, 0xFF000000u, colors, labels, 1};
  shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_OPEN, 3, 41, 0xFF000000u, &chooser);
  w.PumpUntilSeen(1, "OPEN reaches cmux's fn");
  Check(seen.size() == 1 && seen[0].event == CMUX_SHIM_COLOR_CHOOSER_OPEN && seen[0].browser == tab &&
            seen[0].token == 41 && seen[0].color == 0xFF000000u && seen[0].suggestions.size() == 1 &&
            seen[0].suggestions[0].first == 0xFFABCDEFu && seen[0].suggestions[0].second == "brand" &&
            seen_ctx[0] == &other_ctx,
        "OPEN has cmux's browser id, the token, the color, the suggestions and cmux's context");
  client.color_choose(41, 0xFF102030u);
  client.color_choose(41, 0xFF405060u);
  Check(PumpUntil([] { return shim.chosen.size() == 2; }) && shim.chosen[1].second == 0xFF405060u,
        "each live color reaches the host's shim, in order");
  shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_SET_COLOR, 0, 41, 0xFF0000FFu, nullptr);
  shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_END, 0, 41, 0, nullptr);
  w.PumpUntilSeen(3, "SET_COLOR and END reach cmux's fn");
  Check(seen.size() == 3 && seen[1].event == CMUX_SHIM_COLOR_CHOOSER_SET_COLOR && seen[1].color == 0xFF0000FFu &&
            seen[2].event == CMUX_SHIM_COLOR_CHOOSER_END && seen[2].token == 41 && !seen[2].data,
        "SET_COLOR carries the page's color, END ends the token");
  shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_END, 0, 41, 0, nullptr);
  shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_SET_COLOR, 0, 99, 1, nullptr);
  PumpBriefly();
  Check(seen.size() == 3, "an END or SET_COLOR of a token that is not open is dropped");
  client.color_end(41);
  Check(PumpUntil([] { return !shim.color_ended.empty(); }) && shim.color_ended[0] == 41, "cmux's end reaches the host");
  for (const auto& [kind, unused_browser] : events_seen) {
    (void)unused_browser;
    Check(kind != CMUX_SHIM_COLOR_CHOOSER && kind != CMUX_SHIM_DEVICE_CHOOSER && kind != CMUX_SHIM_DESKTOP_MEDIA,
          "a chooser push never reaches cmux's event fn");
  }
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
  client.set_color(nullptr, nullptr);
  PumpBriefly();
}

// Device choosers: each UPDATE has the whole state; cmux's answer has its rows.
void DeviceChooserEndToEnd() {
  World w;
  const int tab = w.CreateWindow();
  client.set_device(&OnDevice, nullptr);
  Check(PumpUntil([] { return shim.device != nullptr; }), "the device handler is installed");
  ForkDeviceChooser state{static_cast<int>(sizeof(ForkDeviceChooser)), 51, "https://usb.test", "title", "none", "Connect",
                          0, 0, 0, 0, 1, 1, 1, 0, nullptr, 0};
  shim.device(shim.device_ctx, CMUX_SHIM_DEVICE_CHOOSER_UPDATE, 3, 51, &state);
  ForkDeviceOption options[] = {{"Token", -1, 0, 0}, {"Pad", -1, 1, 1}};
  state.initialized = 1;
  state.refreshing = 0;
  state.options = options;
  state.option_count = 2;
  shim.device(shim.device_ctx, CMUX_SHIM_DEVICE_CHOOSER_UPDATE, 3, 51, &state);
  w.PumpUntilSeen(2, "both UPDATEs reach cmux's fn");
  Check(seen.size() == 2 && seen[0].browser == tab && seen[0].rows.empty() && seen[0].flags[4] == 1 &&
            seen[1].rows.size() == 2 && std::get<0>(seen[1].rows[1]) == "Pad" && std::get<3>(seen[1].rows[1]) == 1 &&
            seen[1].texts[0] == "https://usb.test" && seen[1].texts[3] == "Connect" && seen[1].flags[3] == 1,
        "each UPDATE carries the whole state: searching, then the rows");
  const cmux_shim_device_choice choice[] = {{1}};
  client.device_answer(51, 0, choice, 1);
  Check(PumpUntil([] { return !shim.device_answers.empty(); }) && std::get<0>(shim.device_answers[0]) == 51 &&
            std::get<1>(shim.device_answers[0]) == 0 && std::get<2>(shim.device_answers[0]) == std::vector<int64_t>{1},
        "cmux's select reaches the host's shim with its row");
  shim.device(shim.device_ctx, CMUX_SHIM_DEVICE_CHOOSER_UPDATE, 3, 52, &state);
  shim.device(shim.device_ctx, CMUX_SHIM_DEVICE_CHOOSER_CLOSE, 0, 52, nullptr);
  w.PumpUntilSeen(4, "another chooser's UPDATE and CLOSE");
  Check(seen[3].event == CMUX_SHIM_DEVICE_CHOOSER_CLOSE && seen[3].token == 52, "Chromium's close reaches cmux's fn");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
  client.set_device(nullptr, nullptr);
  PumpBriefly();
}

// The screen-share picker: OPEN's request, and a shared tab named by cmux's
// id reaches the host as Chromium's.
void DesktopMediaEndToEnd() {
  World w;
  const int tab = w.CreateWindow();
  client.set_media(&OnMedia, nullptr);
  Check(PumpUntil([] { return shim.media != nullptr; }), "the media handler is installed");
  ForkDesktopMediaRequest request{static_cast<int>(sizeof(ForkDesktopMediaRequest)), 61, "share.test", 1 | 2 | 4, 2, 1};
  shim.media(shim.media_ctx, CMUX_SHIM_DESKTOP_MEDIA_OPEN, 3, 61, &request);
  w.PumpUntilSeen(1, "OPEN reaches cmux's fn");
  Check(seen.size() == 1 && seen[0].browser == tab && seen[0].texts[0] == "share.test" && seen[0].flags[0] == 7 &&
            seen[0].flags[1] == 2 && seen[0].flags[2] == 1,
        "OPEN carries the app name, the source types, the preference and audio");
  client.media_answer(61, 4, 0, tab, 1);
  Check(PumpUntil([] { return !shim.media_answers.empty(); }) && std::get<3>(shim.media_answers[0]) == 3 &&
            std::get<1>(shim.media_answers[0]) == 4 && std::get<4>(shim.media_answers[0]) == 1,
        "a shared tab goes to the host as Chromium's browser id");
  Check(w.delegate.bad.empty() && ended == -1, "neither side ended the wire");
  client.set_media(nullptr, nullptr);
  PumpBriefly();
}

// Removal and the host's end end cmux's open requests at its fn, once.
void OpenRequestsEndAtTheOldFn() {
  {
    World w;
    w.CreateWindow();
    client.set_device(&OnDevice, nullptr);
    PumpUntil([] { return shim.device != nullptr; });
    ForkDeviceChooser state{static_cast<int>(sizeof(ForkDeviceChooser)), 71, "", "", "", "", 0, 0, 0, 1, 0, 1, 1, 0,
                            nullptr, 0};
    shim.device(shim.device_ctx, CMUX_SHIM_DEVICE_CHOOSER_UPDATE, 3, 71, &state);
    w.PumpUntilSeen(1, "UPDATE reaches cmux's fn");
    void* host_ctx = shim.device_ctx;
    ChooserFn host_fn = shim.device;
    client.set_device(nullptr, nullptr);
    Check(seen.size() == 2 && seen[1].event == CMUX_SHIM_DEVICE_CHOOSER_CLOSE && seen[1].token == 71,
          "removing the handler closes its open chooser at once, at the old fn");
    // The fork ends it too when the host's handler goes: that CLOSE names a token cmux no longer has.
    host_fn(host_ctx, CMUX_SHIM_DEVICE_CHOOSER_CLOSE, 0, 71, nullptr);
    PumpBriefly();
    Check(seen.size() == 2 && shim.device == nullptr, "the fork's own close after it is dropped");
  }
  {
    World w;
    w.CreateWindow();
    client.set_color(&OnColor, nullptr);
    PumpUntil([] { return shim.color != nullptr; });
    ForkColorChooser chooser{static_cast<int>(sizeof(ForkColorChooser)), 81, 0, nullptr, nullptr, 0};
    shim.color(shim.color_ctx, CMUX_SHIM_COLOR_CHOOSER_OPEN, 3, 81, 0, &chooser);
    w.PumpUntilSeen(1, "OPEN reaches cmux's fn");
    w.Detach();
    Check(seen.size() == 2 && seen[1].event == CMUX_SHIM_COLOR_CHOOSER_END && seen[1].token == 81,
          "the host's end ends cmux's open color chooser");
  }
  client.set_color(nullptr, nullptr);
}

// A setter op with installed outside 0 and 1 is a bad message.
void MalformedSetterEndsTheHost() {
  World w;
  Message bad;
  bad.op = cmux_host::kOpSetColorChooserHandler;
  cmux_host::TlvWriter args;
  args.I32(2);
  bad.fields = args.Take();
  std::vector<Message> batch;
  batch.push_back(std::move(bad));
  w.host.OnMessages(std::move(batch));
  Check(w.delegate.bad.size() == 1, "a malformed chooser setter op ends the host");
}

}  // namespace

int main() {
  PayloadsRoundTrip();
  client = LoadClient();
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ready = &OnReady;
  callbacks.ended = &OnEnded;
  client.configure(&callbacks);
  InstalledAtInitializeAndRemoved();
  ColorChooserEndToEnd();
  DeviceChooserEndToEnd();
  DesktopMediaEndToEnd();
  OpenRequestsEndAtTheOldFn();
  MalformedSetterEndsTheHost();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-choosers tests: ok");
  return EXIT_SUCCESS;
}

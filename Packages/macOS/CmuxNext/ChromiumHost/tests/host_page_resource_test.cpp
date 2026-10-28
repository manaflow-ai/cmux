// cmux-page:// first-party pages through the Chromium Host, end to end: the
// real dispatcher (src/host_dispatch.mm, the generated cases) with a fake shim on one end of a
// socket pair, the real remote shim (client/remote_shim.mm, loaded as the shared library cmux
// loads) on the other.
//
//   - a first-party page scheme added before initialize reaches the host's shim before
//     cmux_shim_initialize, and the host's verdict (1, or 0 for a refusal) comes back as a REPLY
//     under the token cmux_remote_shim_last_reply_token named right after the call;
//   - a PAGE_RESOURCE event reaches cmux with the id cmux minted for the browser, the request's
//     token and its URL;
//   - cmux_shim_page_resource_respond carries a 10 MB body to the host's shim byte for byte (a
//     control frame is at most 64 KiB, so the body rides a sealed shared memory region, task 020).
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
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "cmux_cef_shim.h"
#include "host_dispatch.h"
#include "remote_shim_runtime.h"

namespace {

using cmux_host::HostContext;
using cmux_host::control::Channel;
using cmux_host::control::End;
using cmux_host::control::Field;
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
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
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

// The remote shim's exports, as cmux binds them (CEFShimLibrary).
struct Client {
  decltype(&cmux_remote_shim_configure) configure;
  decltype(&cmux_remote_shim_attach) attach;
  decltype(&cmux_remote_shim_detach) detach;
  decltype(&cmux_remote_shim_last_reply_token) last_reply_token;
  decltype(&cmux_shim_initialize) initialize;
  decltype(&cmux_shim_create_window) create_window;
  decltype(&cmux_shim_page_scheme_add_first_party_dynamic) page_scheme_add_dynamic;
  decltype(&cmux_shim_page_resource_respond) page_resource_respond;
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
  Bind(library, "cmux_remote_shim_last_reply_token", &c.last_reply_token);
  Bind(library, "cmux_shim_initialize", &c.initialize);
  Bind(library, "cmux_shim_create_window", &c.create_window);
  Bind(library, "cmux_shim_page_scheme_add_first_party_dynamic", &c.page_scheme_add_dynamic);
  Bind(library, "cmux_shim_page_resource_respond", &c.page_resource_respond);
  return c;
}

Client client;

// The host's fake shim.
struct Scheme {
  std::string id, root, csp, prefixes, entry;
  bool before_initialize = false;
};
struct Answer {
  int token = 0;
  int status = 0;
  std::string mime;
  std::string body;
};
struct Shim {
  HostContext* host = nullptr;
  bool initialized = false;
  std::vector<Scheme> schemes;
  std::vector<Answer> answers;
  int next_browser = 3;
} shim;

std::string Text(const char* s) { return s ? s : ""; }

void* Resolve(const char*) { return nullptr; }

}  // namespace

extern "C" {
int cmux_shim_page_scheme_add_first_party_dynamic(const char* id, const char* root, const char* csp,
                                                  const char* prefixes, const char* entry) {
  shim.schemes.push_back({Text(id), Text(root), Text(csp), Text(prefixes), Text(entry), !shim.initialized});
  return Text(id) == "cmux.refused" ? 0 : 1;
}
int cmux_shim_page_resource_respond(int token, int status, const char* mime, const void* body, size_t length) {
  shim.answers.push_back({token, status, Text(mime), std::string(static_cast<const char*>(body), length)});
  return 1;
}
int cmux_shim_create_window(int request, void*, int, int, const char*, const char*) {
  HostContext::OnShimEvent(shim.host, CMUX_SHIM_AFTER_CREATED, shim.next_browser++, request, 11, 0, "", "");
  return 1;
}
}

namespace {

struct Delegate : cmux_host::HostDelegate {
  std::function<void()> resume;
  bool resumed = false;
  std::vector<std::string> bad;
  void Initialize(cmux_host::InitializeRequest) override {
    // browser_host_main.mm runs cmux_shim_initialize, then Resume in a task.
    shim.initialized = true;
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

// What cmux's side saw.
struct Event {
  int kind, browser, request;
  std::string s1;
};
std::vector<Event> events;
std::vector<std::pair<uint32_t, int32_t>> verdicts;  // token, the host's answer
bool ready = false;

void OnEvent(void*, int kind, int browser, int request, int64_t, int64_t, const char* s1, const char*) {
  events.push_back({kind, browser, request, Text(s1)});
}
void OnReady(void*) { ready = true; }
void OnReply(void*, uint32_t token, const void* fields, size_t length) {
  std::vector<Field> decoded;
  Check(cmux_host::control::DecodeFields(std::string_view(static_cast<const char*>(fields), length), &decoded),
        "a REPLY's fields decode");
  cmux_host::control::TlvReader r(std::move(decoded));
  const int32_t verdict = r.I32();
  Check(r.ok() && r.AtEnd(), "a page scheme's verdict is one int");
  verdicts.emplace_back(token, verdict);
}

}  // namespace

int main() {
  client = LoadClient();
  cmux_remote_shim_callbacks callbacks = {};
  callbacks.post_main = &PostMain;
  callbacks.ready = &OnReady;
  callbacks.reply = &OnReply;
  client.configure(&callbacks);

  Delegate delegate;
  Views views;
  std::unique_ptr<Channel> channel;
  HostContext host{[&channel](const Message& m) { return channel && channel->Send(m); }, delegate, views, &Resolve};
  shim.host = &host;
  delegate.resume = [&host] { host.Resume(); };

  // Before attach: the scheme goes in the replay log, its verdict asked once the host is there.
  Check(client.page_scheme_add_dynamic("cmux.diff", "/pages/diff", "default-src 'self'", "__patch", "diff-page.html") == 1,
        "the client's own check takes a first-party page");
  const uint32_t diff_token = client.last_reply_token();
  Check(diff_token != 0, "a page scheme's verdict has a token");
  Check(client.page_scheme_add_dynamic("cmux.refused", "/pages/x", nullptr, nullptr, nullptr) == 1,
        "the client cannot know the host's refusal");
  const uint32_t refused_token = client.last_reply_token();
  Check(refused_token != 0 && refused_token != diff_token, "each verdict has its own token");
  Check(client.page_scheme_add_dynamic("not-reserved", "/pages/x", nullptr, nullptr, nullptr) == 0,
        "the client's own check refuses a page that is not first-party");
  Check(client.last_reply_token() == 0, "a refusal before the wire names no token");

  int pair[2];
  Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "socketpair");
  channel = std::make_unique<Channel>(
      pair[1], &PostTask, [&host](std::vector<Message> batch) { host.OnMessages(std::move(batch)); }, [](End) {});
  host.Attach();
  Check(client.attach(pair[0], nullptr, nullptr) == 1, "the remote shim attaches");
  const char* switches[] = {nullptr};
  Check(client.initialize("/fw", "/app", "/helper", "/root", nullptr, 0, nullptr, nullptr, switches, nullptr, nullptr,
                          &OnEvent, nullptr) == 1,
        "initialize is sent");
  Check(PumpUntil([&] { return ready && delegate.resumed && verdicts.size() == 2; }),
        "the hellos, the verdicts and initialize go through");

  // Scheme registration is preinit: the host's shim had both before cmux_shim_initialize.
  Check(shim.schemes.size() == 2, "the host's shim got each first-party page once");
  if (shim.schemes.size() == 2) {
    const Scheme& diff = shim.schemes[0];
    Check(diff.id == "cmux.diff" && diff.root == "/pages/diff" && diff.csp == "default-src 'self'" &&
              diff.prefixes == "__patch" && diff.entry == "diff-page.html",
          "the page's arguments reach the host as cmux gave them");
    Check(diff.before_initialize && shim.schemes[1].before_initialize, "a page scheme applies before initialize");
  }
  Check(verdicts.size() == 2 && verdicts[0] == std::make_pair(diff_token, 1) &&
            verdicts[1] == std::make_pair(refused_token, 0),
        "each verdict comes under its call's token: 1, then the host's refusal");

  // A page view's browser, by the id cmux minted.
  Check(client.create_window(42, nullptr, 800, 600, "cmux-page://cmux.diff/", nullptr) == 1, "create_window is sent");
  Check(PumpUntil([] { return !events.empty() && events.back().kind == CMUX_SHIM_AFTER_CREATED; }),
        "the window's AFTER_CREATED reaches cmux");
  const int minted = events.empty() ? 0 : events.back().browser;
  const int chromium = shim.next_browser - 1;
  Check(minted != chromium && minted != 0, "cmux knows the browser by its minted id");

  // The page asks for a dynamic path: PAGE_RESOURCE on the host's UI thread, in cmux's ids.
  const std::string url = "cmux-page://cmux.diff/__patch/0.diff";
  HostContext::OnShimEvent(&host, CMUX_SHIM_PAGE_RESOURCE, chromium, 77, 0, 0, url.c_str(), "");
  Check(PumpUntil([] { return events.back().kind == CMUX_SHIM_PAGE_RESOURCE; }), "PAGE_RESOURCE reaches cmux");
  const Event& asked = events.back();
  Check(asked.browser == minted && asked.request == 77 && asked.s1 == url,
        "PAGE_RESOURCE carries the minted browser, the request's token and its URL");

  // cmux's answer: a body far past one control frame.
  std::string body(10 * 1024 * 1024, '\0');
  for (size_t i = 0; i < body.size(); ++i) body[i] = static_cast<char>((i * 131u + 7u) & 0xffu);
  Check(client.page_resource_respond(77, 200, "text/x-diff", body.data(), body.size()) == 1, "the answer is posted");
  Check(PumpUntil([] { return !shim.answers.empty(); }), "the answer reaches the host's shim");
  if (!shim.answers.empty()) {
    const Answer& answer = shim.answers[0];
    Check(answer.token == 77 && answer.status == 200 && answer.mime == "text/x-diff", "the answer's header is cmux's");
    Check(answer.body == body, "the 10 MB body arrives byte for byte");
  }
  Check(delegate.bad.empty(), "no frame broke the wire's rules");

  client.detach();
  channel->Close();
  channel.reset();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host page resources: ok");
  return EXIT_SUCCESS;
}

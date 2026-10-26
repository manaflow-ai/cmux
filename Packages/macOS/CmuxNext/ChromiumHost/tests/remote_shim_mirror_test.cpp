// Checks the remote shim's mirror cache (client/remote_shim_mirror.h) through
// the generated client exports (remote_shim.inc, written fresh by
// scripts/cmux-next/tests/remote-shim-mirror.test.sh): a post marks its keys
// pending until the host's ACK, a read in the same turn never returns the
// value from before the post, a read after the ACK returns the value the
// host's dispatch refreshed before that ACK, and a batch applies MIRROR frames
// in order with its events. The cmux_remote wire interface below is a fake transport over
// the real cache; the real one is remote_shim.mm (task 014).
#include <algorithm>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

extern "C" {
#include "cmux_cef_shim.h"
}

#include "../client/remote_shim_mirror.h"

namespace cmux_remote {

using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::control::Type;

MirrorCache& Cache() {
  static MirrorCache cache;
  return cache;
}

struct Sent {
  uint16_t op;
  uint32_t token;
};
std::vector<Sent> sent;
bool connected = true;
uint32_t last_token = 0;
int32_t last_minted = 1 << 20;

struct TlvWriter {
  std::vector<Field> fields;
  void I32(int32_t value) { fields.push_back(Field::I32(0, value)); }
  void U32(uint32_t value) { I32(static_cast<int32_t>(value)); }
  void I64(int64_t value) { fields.push_back(Field::I64(0, value)); }
  void F64(double value) { fields.push_back(Field::F64(0, value)); }
  void Str(const char* text) { fields.push_back(Field::Str(text ? 0 : 1, text ? text : "")); }
  void Bytes(const void* data, size_t length) {
    fields.push_back(Field::Bytes(0, data && length ? std::string(static_cast<const char*>(data), length) : ""));
  }
  void View(void* view) { I64(static_cast<int64_t>(reinterpret_cast<uintptr_t>(view))); }
  void StrList(const char* const* items, int count) {
    I32(count);
    for (int i = 0; i < count; ++i) Str(items[i]);
  }
};

// A cached value, or nothing (absent or the pending marker).
struct TlvReader {
  const std::vector<Field>* fields = nullptr;
  size_t next = 0;

  bool present() const { return fields != nullptr && next < fields->size(); }
  const Field* Next() { return present() ? &(*fields)[next++] : nullptr; }
  int32_t I32() {
    const Field* f = Next();
    return f ? static_cast<int32_t>(f->integer) : 0;
  }
  uint32_t U32() { return static_cast<uint32_t>(I32()); }
  int64_t I64() {
    const Field* f = Next();
    return f ? f->integer : 0;
  }
  std::optional<std::string> Str() {
    const Field* f = Next();
    if (f == nullptr || f->tag == 1) return std::nullopt;
    return f->bytes;
  }
  std::string Bytes() {
    const Field* f = Next();
    return f ? f->bytes : std::string();
  }
  void I32Array(int* out, int capacity) {
    const Field* f = Next();
    if (f == nullptr) return;
    for (int i = 0; i < capacity && static_cast<size_t>(i) * 4 + 4 <= f->bytes.size(); ++i) {
      std::memcpy(&out[i], f->bytes.data() + i * 4, 4);
    }
  }
};

// As remote_shim.mm must: a post that is not sent drops its pending marks.
bool Post(uint16_t op, uint32_t token, const TlvWriter&) {
  if (!connected) {
    if (token != 0) Cache().DropPending(token);
    return false;
  }
  sent.push_back({op, token});
  return true;
}
bool PostInput(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w); }
bool PostAwaitingReply(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w); }
int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w) ? 1 : 0; }
uint32_t NextToken() { return ++last_token; }
int32_t MintID(uint16_t) { return ++last_minted; }
char* Dup(const std::string& text) {
  char* copy = static_cast<char*>(std::malloc(text.size() + 1));
  std::memcpy(copy, text.c_str(), text.size() + 1);
  return copy;
}
void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards) {
  Cache().MarkPending(mirror_op, token, key.fields, wildcards);
}
TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key) {
  return TlvReader{Cache().Lookup(mirror_op, key.fields).value, 0};
}
void SetPolicy(uint16_t, void*) {}

}  // namespace cmux_remote

#include "remote_shim.inc"

namespace {

using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_remote::Cache;
using cmux_remote::MirrorCache;

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// HostContext::PushMirror's frame for a one-int key.
Message Mirror(uint16_t op, int32_t key, const char* value) {
  Message m;
  m.op = MirrorCache::kMirrorOp;
  m.fields = {Field::I32(0, op), Field::I32(0, 1), Field::I32(0, key), Field::Str(0, value)};
  return m;
}

Message Ack(uint32_t token) {
  Message m;
  m.op = MirrorCache::kAckOp;
  m.reply = true;
  m.token = token;
  return m;
}

Message Event(int32_t kind) {
  Message m;
  m.op = cmux_remote::kOpEvent;
  m.fields = {Field::I32(0, kind)};
  return m;
}

// The generated export's result as a string ("<null>" for NULL), freed.
std::string Take(char* value) {
  if (value == nullptr) return "<null>";
  std::string text = value;
  std::free(value);
  return text;
}

std::string NavigationState(int browser) { return Take(cmux_shim_tab_navigation_state(browser)); }

uint32_t LastToken(uint16_t op) {
  for (auto it = cmux_remote::sent.rbegin(); it != cmux_remote::sent.rend(); ++it) {
    if (it->op == op) return it->token;
  }
  return 0;
}

void GoBackReadsThePendingStateInTheSameTurn() {
  std::vector<std::string> seen;
  const bool ok = Cache().ApplyBatch(
      {Mirror(cmux_remote::kOpTabNavigationState, 7, "old"), Mirror(cmux_remote::kOpTabNavigationState, 8, "eight"),
       Event(CMUX_SHIM_LOAD_START)},
      [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(ok && seen == std::vector<std::string>{"old"}, "the event reads the value pushed before it");

  cmux_shim_go_back(7);
  const uint32_t token = LastToken(cmux_remote::kOpGoBack);
  Check(token != 0, "go_back is sent with a token for its ACK");
  Check(NavigationState(7) == "<null>", "go_back then tab_navigation_state in the same turn: pending, not the old value");
  Check(Take(cmux_shim_tab_navigation_entries(7)) == "<null>", "the entries are pending too");
  Check(NavigationState(8) == "eight", "another tab's state is not pending");

  // What host_dispatch.inc's go_back case sends (remote-shim-mirror.test.sh checks it): after an
  // event already queued, the call, RefreshMirror of both pending keys (Chrome's state with the
  // pending entry), then the ACK. The navigation commits frames later and pushes again before its
  // LOAD_START.
  seen.clear();
  Cache().ApplyBatch({Event(CMUX_SHIM_PROGRESS), Mirror(cmux_remote::kOpTabNavigationEntries, 7, "entries"),
                      Mirror(cmux_remote::kOpTabNavigationState, 7, "back pending"), Ack(token),
                      Event(CMUX_SHIM_PROGRESS)},
                     [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(seen == std::vector<std::string>{"<null>", "back pending"},
        "pending until the ACK, then the host's value after the op");
  Check(NavigationState(7) == "back pending", "between the ACK and the commit: never the old value");
  Check(Cache().pending_count() == 0, "the ACK cleared every mark of its token");
  seen.clear();
  Cache().ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "new"), Event(CMUX_SHIM_LOAD_START)},
                     [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(seen == std::vector<std::string>{"new"}, "the commit's LOAD_START reads the committed state");
}

void ANewerPostStaysPendingAfterAnOlderAck() {
  cmux_shim_go_back(7);
  const uint32_t first = LastToken(cmux_remote::kOpGoBack);
  cmux_shim_go_forward(7);
  const uint32_t second = LastToken(cmux_remote::kOpGoForward);
  Cache().ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "back"), Ack(first)}, [](const Message&) {});
  Check(NavigationState(7) == "<null>", "the forward is still pending after the back's ACK");
  Cache().ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "forward"), Ack(second)}, [](const Message&) {});
  Check(NavigationState(7) == "forward", "both ACKs in: the host's value");
}

void APostThatWasNotSentLeavesNoMark() {
  cmux_remote::connected = false;
  cmux_shim_go_back(7);
  cmux_remote::connected = true;
  Check(Cache().pending_count() == 0, "an unsent post drops its marks");
  Check(NavigationState(7) == "forward", "and the cached value reads");
}

void AWildcardMarksEveryKey() {
  Message list3 = Mirror(cmux_remote::kOpExtList, 3, "[a]");
  Message list4 = Mirror(cmux_remote::kOpExtList, 4, "[b]");
  Cache().ApplyBatch({list3, list4}, [](const Message&) {});
  cmux_shim_ext_set_enabled(3, "ext", 0);
  const uint32_t token = LastToken(cmux_remote::kOpExtSetEnabled);
  Check(Take(cmux_shim_ext_list(3)) == "<null>" && Take(cmux_shim_ext_list(4)) == "<null>",
        "ext_list[*] marks every tab's list");
  Cache().ApplyBatch({Ack(token)}, [](const Message&) {});
  Check(Take(cmux_shim_ext_list(4)) == "[b]", "the ACK clears the wildcard");

  // A two-parameter key whose second parameter is `*` (bit 1).
  Cache().MarkPending(cmux_remote::kOpExtActions, 900, {Field::I32(0, 3)}, 0x2u);
  Check(Cache().Lookup(cmux_remote::kOpExtActions, {Field::I32(0, 3), Field::I32(0, 16)}).state ==
            MirrorCache::State::kPending,
        "a named parameter with a wildcard after it matches");
  Check(Cache().Lookup(cmux_remote::kOpExtActions, {Field::I32(0, 4), Field::I32(0, 16)}).state ==
            MirrorCache::State::kAbsent,
        "another value of the named parameter does not");
  Cache().DropPending(900);
}

void AnOptimisticValueReadsUntilTheAck() {
  const MirrorCache::Fields moved = {Field::I32(0, 42)};
  Cache().MarkPending(cmux_remote::kOpTabWindowId, 901, {Field::I32(0, 7)}, 0, moved);
  Check(cmux_shim_tab_window_id(7) == 42, "the optimistic window id reads at once");
  Cache().ApplyBatch({Ack(901)}, [](const Message&) {});
  Check(cmux_shim_tab_window_id(7) == 0, "after the ACK, the host's value (none pushed)");
}

void MalformedFramesEndTheBatch() {
  int events = 0;
  auto count = [&](const Message&) { ++events; };
  Message too_many_keys = Mirror(cmux_remote::kOpTabNavigationState, 7, "x");
  too_many_keys.fields[1] = Field::I32(0, 3);
  Check(!Cache().ApplyBatch({too_many_keys, Event(1)}, count) && events == 0,
        "a key count past the frame ends the batch before its event");
  Message no_op = Mirror(0, 7, "x");
  Check(Cache().Apply(no_op) == MirrorCache::Applied::kMalformed, "op 0 is no export");
  Message ack = Ack(5);
  ack.reply = false;
  Check(Cache().Apply(ack) == MirrorCache::Applied::kMalformed, "an ACK is a reply frame");
  Check(Cache().Apply(Ack(0)) == MirrorCache::Applied::kMalformed, "an ACK names a token");
  Message mirror_reply = Mirror(cmux_remote::kOpTabNavigationState, 7, "x");
  mirror_reply.reply = true;
  Check(Cache().Apply(mirror_reply) == MirrorCache::Applied::kMalformed, "a MIRROR answers no token");
  Check(Cache().Apply(Ack(12345)) == MirrorCache::Applied::kApplied, "an ACK of an op without marks is fine");
  Check(NavigationState(7) == "forward", "nothing malformed reached the cache");
}

void TheHostEndingClearsTheCache() {
  cmux_shim_go_back(8);
  Cache().Clear();
  Check(Cache().pending_count() == 0 && NavigationState(7) == "<null>" && NavigationState(8) == "<null>",
        "no value or mark outlives its host");
}

// Off the main thread the cache aborts (its main-thread assert), in a child
// process so the abort ends only the child.
bool OffMainReadAborts() {
  const pid_t child = fork();
  if (child == 0) {
    if (std::freopen("/dev/null", "w", stderr) == nullptr) _exit(2);  // hides the expected assert message
    std::thread([] { (void)Cache().Lookup(cmux_remote::kOpTabNavigationState, {Field::I32(0, 7)}); }).join();
    _exit(0);
  }
  int status = 0;
  return child > 0 && waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

}  // namespace

int main() {
  GoBackReadsThePendingStateInTheSameTurn();
  ANewerPostStaysPendingAfterAnOlderAck();
  APostThatWasNotSentLeavesNoMark();
  AWildcardMarksEveryKey();
  AnOptimisticValueReadsUntilTheAck();
  MalformedFramesEndTheBatch();
  TheHostEndingClearsTheCache();
  Check(OffMainReadAborts(), "a read off the main thread aborts");
  if (failures != 0) return 1;
  std::printf("remote shim mirror: ok\n");
  return 0;
}

// Checks the remote shim's mirror cache (client/remote_shim_mirror.h) through
// the generated client exports (remote_shim.inc, written fresh by
// scripts/cmux-next/tests/remote-shim-mirror.test.sh), task 016b: a post marks
// its keys pending until the host's ACK, a read in the same turn never returns
// the value from before the post, a read after the ACK returns the value the
// host's dispatch refreshed before that ACK (HostContext::RefreshMirror), and
// MIRROR frames apply in order with the events of their batch. The transport
// below is a fake over the real cache; the real one is remote_shim.mm, whose
// Apply decodes the same frames (remote_shim_test.cpp runs it on a socket).
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

extern "C" {
#include "cmux_cef_shim.h"
}

#include "remote_shim_mirror.h"
#include "remote_shim_runtime.h"

#include "remote_shim.inc"

namespace cmux_remote {

using cmux_host::control::Field;
using cmux_host::control::Message;

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
int32_t last_minted = kFirstMintedBrowserID;

void TlvWriter::View(void* view_token) {
  ViewToken(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(view_token)));
}

// As remote_shim.mm's Forget: a post that is not sent clears its pending marks.
bool Post(uint16_t op, uint32_t token, const TlvWriter&) {
  if (!connected) {
    if (token != 0) Cache().Ack(token);
    return false;
  }
  sent.push_back({op, token});
  return true;
}
bool PostInput(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w); }
bool PostForReply(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w); }
int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter& w) { return Post(op, token, w) ? 1 : 0; }
uint32_t NextToken() { return ++last_token; }
int32_t MintID(uint16_t) { return ++last_minted; }
char* Dup(const std::string& text) {
  char* copy = static_cast<char*>(std::malloc(text.size() + 1));
  std::memcpy(copy, text.c_str(), text.size() + 1);
  return copy;
}
void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards) {
  Cache().MarkPending(mirror_op, token, key.fields(), wildcards);
}
TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key) { return Cache().Lookup(mirror_op, key.fields()); }
void SetPolicy(uint16_t, void*) {}
void* Policy(uint16_t) { return nullptr; }
void* InputRing() { return nullptr; }
void* OutputRing() { return nullptr; }

}  // namespace cmux_remote

namespace {

using cmux_host::control::DecodeFields;
using cmux_host::control::EncodeFields;
using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_remote::Cache;
using cmux_remote::TlvReader;
using cmux_remote::TlvWriter;

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// HostContext::PushMirror's frame for a one-int key: i32 mirror op, bytes key, bytes value.
Message Mirror(uint16_t op, int32_t key, const char* value) {
  TlvWriter k;
  k.I32(key);
  TlvWriter v;
  v.Str(value);
  std::string key_bytes, value_bytes;
  EncodeFields(k.fields(), &key_bytes);
  EncodeFields(v.fields(), &value_bytes);
  TlvWriter m;
  m.I32(op);
  m.Bytes(key_bytes.data(), key_bytes.size());
  m.Bytes(value_bytes.data(), value_bytes.size());
  Message message;
  message.op = cmux_remote::kOpMirror;
  message.fields = m.Take();
  return message;
}

Message Ack(uint32_t token) {
  Message m;
  m.op = cmux_remote::kOpAck;
  m.reply = true;
  m.token = token;
  return m;
}

Message Event(int32_t kind) {
  TlvWriter w;
  w.I32(kind);
  Message m;
  m.op = cmux_remote::kOpEvent;
  m.fields = w.Take();
  return m;
}

// remote_shim.mm's Apply for MIRROR and ACK, over one batch in arrival order; other messages
// go to `other` as they come.
void ApplyBatch(const std::vector<Message>& batch, const std::function<void(const Message&)>& other) {
  for (const Message& message : batch) {
    if (message.op == cmux_remote::kOpAck) {
      Cache().Ack(message.token);
      continue;
    }
    if (message.op != cmux_remote::kOpMirror) {
      other(message);
      continue;
    }
    TlvReader r(message.fields);
    const int32_t op = r.I32();
    const std::string key_bytes = r.Bytes();
    const std::string value_bytes = r.Bytes();
    std::vector<Field> key, value;
    Check(r.ok() && r.AtEnd() && DecodeFields(key_bytes, &key) && DecodeFields(value_bytes, &value),
          "a well-formed MIRROR frame");
    Cache().Set(static_cast<uint16_t>(op), key, std::move(value));
  }
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
  ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "old"),
              Mirror(cmux_remote::kOpTabNavigationState, 8, "eight"), Event(CMUX_SHIM_LOAD_START)},
             [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(seen == std::vector<std::string>{"old"}, "the event reads the value pushed before it");

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
  ApplyBatch({Event(CMUX_SHIM_PROGRESS), Mirror(cmux_remote::kOpTabNavigationEntries, 7, "entries"),
              Mirror(cmux_remote::kOpTabNavigationState, 7, "back pending"), Ack(token), Event(CMUX_SHIM_PROGRESS)},
             [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(seen == std::vector<std::string>{"<null>", "back pending"},
        "pending until the ACK, then the host's value after the op");
  Check(Cache().pending() == 0, "the ACK cleared every mark of its token");
  seen.clear();
  ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "new"), Event(CMUX_SHIM_LOAD_START)},
             [&](const Message&) { seen.push_back(NavigationState(7)); });
  Check(seen == std::vector<std::string>{"new"}, "the commit's LOAD_START reads the committed state");
}

void ANewerPostStaysPendingAfterAnOlderAck() {
  cmux_shim_go_back(7);
  const uint32_t first = LastToken(cmux_remote::kOpGoBack);
  cmux_shim_go_forward(7);
  const uint32_t second = LastToken(cmux_remote::kOpGoForward);
  ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "back"), Ack(first)}, [](const Message&) {});
  Check(NavigationState(7) == "<null>", "the forward is still pending after the back's ACK");
  ApplyBatch({Mirror(cmux_remote::kOpTabNavigationState, 7, "forward"), Ack(second)}, [](const Message&) {});
  Check(NavigationState(7) == "forward", "both ACKs in: the host's value");
}

void APostThatWasNotSentLeavesNoMark() {
  cmux_remote::connected = false;
  cmux_shim_go_back(7);
  cmux_remote::connected = true;
  Check(Cache().pending() == 0, "an unsent post drops its marks");
  Check(NavigationState(7) == "forward", "and the cached value reads");
}

void AWildcardMarksEveryKey() {
  ApplyBatch({Mirror(cmux_remote::kOpExtList, 3, "[a]"), Mirror(cmux_remote::kOpExtList, 4, "[b]")},
             [](const Message&) {});
  cmux_shim_ext_set_enabled(3, "ext", 0);
  const uint32_t token = LastToken(cmux_remote::kOpExtSetEnabled);
  Check(Take(cmux_shim_ext_list(3)) == "<null>" && Take(cmux_shim_ext_list(4)) == "<null>",
        "ext_list[*] marks every tab's list");
  ApplyBatch({Ack(token)}, [](const Message&) {});
  Check(Take(cmux_shim_ext_list(4)) == "[b]", "the ACK clears the wildcard");

  // A two-parameter key whose second parameter is `*` (bit 1).
  Cache().MarkPending(cmux_remote::kOpExtActions, 900, {Field::I32(0, 3)}, 0x2u);
  Check(!Cache().Lookup(cmux_remote::kOpExtActions, {Field::I32(0, 3), Field::I32(0, 16)}).present(),
        "a named parameter with a wildcard after it matches");
  Cache().Set(cmux_remote::kOpExtActions, {Field::I32(0, 4), Field::I32(0, 16)}, {Field::Str(0, "four")});
  Check(Cache().Lookup(cmux_remote::kOpExtActions, {Field::I32(0, 4), Field::I32(0, 16)}).present(),
        "another value of the named parameter does not");
  Cache().Ack(900);
}

void TheHostEndingClearsTheCache() {
  cmux_shim_go_back(8);
  Cache().Clear();
  Check(Cache().pending() == 0 && NavigationState(7) == "<null>" && NavigationState(8) == "<null>",
        "no value or mark outlives its host");
}

}  // namespace

int main() {
  GoBackReadsThePendingStateInTheSameTurn();
  ANewerPostStaysPendingAfterAnOlderAck();
  APostThatWasNotSentLeavesNoMark();
  AWildcardMarksEveryKey();
  TheHostEndingClearsTheCache();
  if (failures != 0) return 1;
  std::printf("remote shim mirror: ok\n");
  return 0;
}

// Checks chromium_host_tlv.h: every value the generated ops carry survives a
// control frame (chromium_host_control.h) unchanged, NULL stays apart from
// "", and a field of the wrong type, a missing field or a list longer than
// the message fails the read. Run by scripts/cmux-next/tests/chromium-host-tlv.test.sh.
#include "../src/chromium_host_tlv.h"

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

namespace {

int failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
  }
}

using cmux_host::control::Field;
using cmux_host::control::Message;
using cmux_host::tlv::Reader;
using cmux_host::tlv::Writer;

// The fields after a trip through one encoded frame.
std::vector<Field> RoundTrip(const Writer& writer) {
  Message message;
  message.op = 35;
  message.token = 7;
  message.fields = writer.fields();
  std::vector<uint8_t> bytes;
  if (!cmux_host::control::Encode(message, &bytes)) {
    Check(false, "Encode refused the fields");
    return {};
  }
  std::deque<int> fds;
  Message decoded;
  size_t consumed = 0;
  const auto parse = cmux_host::control::Decode(bytes.data(), bytes.size(), &fds, &decoded, &consumed);
  Check(parse == cmux_host::control::Parse::kFrame && consumed == bytes.size(), "Decode reads the frame back");
  return decoded.fields;
}

void EveryType() {
  Writer w;
  w.I32(-5);
  w.U32(0xFFFFFFF0u);
  w.I64(-(int64_t{1} << 40));
  w.F64(1.25);
  w.Str("https://example.com/");
  w.Str("");
  w.Str(nullptr);
  const char bytes[] = {'\0', 'a', '\xff'};
  w.Bytes(bytes, sizeof bytes);
  w.ViewToken(uint64_t{1} << 33);
  const char* list[] = {"--a", "--b=c"};
  w.StrList(list, 2);
  const int values[] = {1, -2, 0x7fffffff};
  w.I32Array(values, 3);
  const std::vector<Field> fields = RoundTrip(w);

  Reader r(fields);
  Check(r.I32() == -5, "i32");
  Check(r.U32() == 0xFFFFFFF0u, "u32 keeps its bits");
  Check(r.I64() == -(int64_t{1} << 40), "i64");
  Check(r.F64() == 1.25, "f64");
  Check(r.Str() == std::optional<std::string>("https://example.com/"), "str");
  const std::optional<std::string> empty = r.Str();
  Check(empty.has_value() && empty->empty(), "\"\" stays a value");
  Check(!r.Str().has_value(), "NULL stays NULL");
  Check(r.Bytes() == std::string(bytes, sizeof bytes), "bytes keep NUL and high bytes");
  Check(r.View() == uint64_t{1} << 33, "view token");
  Check(r.StrList() == std::vector<std::string>({"--a", "--b=c"}), "str list");
  int out[3] = {0, 0, 0};
  Check(r.I32Array(out, 3) == 3 && out[0] == 1 && out[1] == -2 && out[2] == 0x7fffffff, "i32 array");
  Check(r.ok() && r.AtEnd(), "every field read");
}

void WrongType() {
  Writer w;
  w.Str("1");
  Reader r(w.fields());
  Check(r.I32() == 0 && !r.ok(), "a str read as i32 fails");
  Check(!r.Str().has_value() && !r.ok(), "a failed reader stays failed");
}

void PastTheEnd() {
  Writer w;
  w.I32(1);
  Reader r(w.fields());
  r.I32();
  Check(r.ok() && r.AtEnd(), "one field read");
  Check(r.I64() == 0 && !r.ok(), "a read past the end fails");
}

void ExtraFields() {
  Writer w;
  w.I32(1);
  w.I32(2);
  Reader r(w.fields());
  r.I32();
  Check(r.ok() && !r.AtEnd(), "a field left over is not the end (the generated code refuses the op)");
}

void ListLongerThanMessage() {
  Writer w;
  w.I32(1000);  // the count of a list with one item
  w.Str("only");
  Reader r(w.fields());
  Check(r.StrList().empty() && !r.ok(), "a list count past the message fails");
}

void NullInList() {
  Writer w;
  w.I32(1);
  w.Str(nullptr);
  Reader r(w.fields());
  Check(r.StrList().empty() && !r.ok(), "a NULL item in a list fails");
}

void ArrayIsNotBytes() {
  Writer w;
  const int values[] = {4};
  w.I32Array(values, 1);
  w.Bytes("x", 1);
  Reader r(w.fields());
  Check(r.Bytes().empty() && !r.ok(), "an i32 array is not bytes");
  Reader s(w.fields(), 1, 2);
  int out[1] = {0};
  Check(s.I32Array(out, 1) == 0 && !s.ok(), "bytes are not an i32 array");
}

void Range() {
  Writer w;
  w.I32(9);    // a mirror's op
  w.I32(1);    // key field count
  w.I32(42);   // key
  w.Str("v");  // value
  Reader key(w.fields(), 2, 3);
  Check(key.I32() == 42 && key.ok() && key.AtEnd(), "a reader over a key range");
  Reader value(w.fields(), 3, 99);
  Check(value.Str() == std::optional<std::string>("v") && value.AtEnd(), "an end past the fields is clamped");
}

}  // namespace

int main() {
  EveryType();
  WrongType();
  PastTheEnd();
  ExtraFields();
  ListLongerThanMessage();
  NullInList();
  ArrayIsNotBytes();
  Range();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-tlv tests: ok");
  return EXIT_SUCCESS;
}

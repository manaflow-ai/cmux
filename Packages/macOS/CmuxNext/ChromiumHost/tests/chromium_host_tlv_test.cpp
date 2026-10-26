// Checks chromium_host_tlv.h: every value the generated ops carry survives a
// control frame (chromium_host_control.h) unchanged, NULL stays apart from
// "", a field of the wrong type, a missing field or a list longer than the
// message fails the read, and a nested body (a mirror key or value) decodes
// to the fields it encoded. Run by scripts/cmux-next/tests/chromium-host-tlv.test.sh.
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
using Reader = cmux_host::control::TlvReader;
using Writer = cmux_host::control::TlvWriter;

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

  Reader r{std::vector<Field>(fields)};
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
  Reader r(w.Take());
  Check(r.I32() == 0 && !r.ok(), "a str read as i32 fails");
  Check(!r.Str().has_value() && !r.ok(), "a failed reader stays failed");
}

void PastTheEnd() {
  Writer w;
  w.I32(1);
  Reader r(w.Take());
  r.I32();
  Check(r.ok() && r.AtEnd(), "one field read");
  Check(r.I64() == 0 && !r.ok(), "a read past the end fails");
}

void ExtraFields() {
  Writer w;
  w.I32(1);
  w.I32(2);
  Reader r(w.Take());
  r.I32();
  Check(r.ok() && !r.AtEnd(), "a field left over is not the end (the generated code refuses the op)");
}

void ListLongerThanMessage() {
  Writer w;
  w.I32(1000);  // the count of a list with one item
  w.Str("only");
  Reader r(w.Take());
  Check(r.StrList().empty() && !r.ok(), "a list count past the message fails");
}

void NestedBody() {
  Writer key;
  key.I32(42);
  key.Str(nullptr);
  key.Str("v");
  std::string body;
  Check(key.Encode(&body), "a key encodes as one body");
  std::vector<Field> fields;
  Check(cmux_host::control::DecodeFields(body, &fields), "the body decodes");
  Reader r(std::move(fields));
  Check(r.I32() == 42 && !r.Str().has_value() && r.Str() == std::optional<std::string>("v") && r.ok() && r.AtEnd(),
        "the nested fields read back, NULL included");
  std::vector<Field> none;
  Check(cmux_host::control::DecodeFields(std::string(), &none) && none.empty(), "an empty body is no fields");
  Check(!cmux_host::control::DecodeFields(std::string("\x01\x00\x09\x00", 4), &none),
        "a field past the body's end is malformed");
}

}  // namespace

int main() {
  EveryType();
  WrongType();
  PastTheEnd();
  ExtraFields();
  ListLongerThanMessage();
  NestedBody();
  if (failures) return EXIT_FAILURE;
  std::puts("chromium-host-tlv tests: ok");
  return EXIT_SUCCESS;
}

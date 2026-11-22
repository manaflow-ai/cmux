// Checks cmux_shim::TopLevelDevToolsId (CEFShim/src/devtools_message_id.h):
// the top-level "id" of a DevTools protocol message without a full JSON
// parse (scripts/cmux-next/test-shim-devtools-id-cpp.sh).
#include <cstdio>
#include <string>

#include "../src/devtools_message_id.h"

using cmux_shim::DevToolsIdKind;

static int failures = 0;
static int cases = 0;

static void Expect(const std::string& message, DevToolsIdKind kind, long long id = 0) {
  ++cases;
  long long got = -1;
  DevToolsIdKind result = cmux_shim::TopLevelDevToolsId(message.data(), message.size(), &got);
  if (result != kind || (kind == DevToolsIdKind::kInt && got != id)) {
    ++failures;
    std::fprintf(stderr, "FAIL %s: kind %d id %lld\n", message.c_str(), static_cast<int>(result), got);
  }
}

int main() {
  Expect(R"({"id":1073741830,"result":{}})", DevToolsIdKind::kInt, 1073741830);
  Expect(R"( { "id" : 7 , "error":{"code":-32601}} )", DevToolsIdKind::kInt, 7);
  Expect(R"({"sessionId":"S","id":1073741831,"error":{}})", DevToolsIdKind::kInt, 1073741831);
  Expect(R"({"id":1073741832,"result":{"result":{"value":"\ud800 lone"}},"sessionId":"S"})",
         DevToolsIdKind::kInt, 1073741832);
  std::string deep = R"({"id":1073741833,"result":)";
  for (int i = 0; i < 300; ++i) deep += "[";
  for (int i = 0; i < 300; ++i) deep += "]";
  deep += "}";
  Expect(deep, DevToolsIdKind::kInt, 1073741833);
  Expect(R"({"method":"Page.loadEventFired","params":{"id":5}})", DevToolsIdKind::kNone);
  Expect(R"({"method":"Runtime.consoleAPICalled","params":{"text":"\"id\":5"}})", DevToolsIdKind::kNone);
  Expect(R"({"result":{"id":9},"id":10})", DevToolsIdKind::kInt, 10);
  Expect(R"({"id":5,"id":1073741824})", DevToolsIdKind::kInvalid);
  Expect(R"({"id":1073741824.5})", DevToolsIdKind::kInvalid);
  Expect(R"({"id":1e9})", DevToolsIdKind::kInvalid);
  Expect(R"({"id":"1073741824"})", DevToolsIdKind::kInvalid);
  Expect(R"({"id":-3})", DevToolsIdKind::kInt, -3);
  Expect(R"({"id":99999999999999999999})", DevToolsIdKind::kInvalid);
  Expect(R"([1,2])", DevToolsIdKind::kInvalid);
  Expect("not json", DevToolsIdKind::kInvalid);
  Expect(R"({"id":12,"result":{})", DevToolsIdKind::kInvalid);
  Expect("", DevToolsIdKind::kInvalid);
  std::printf("%d cases, %d failures\n", cases, failures);
  return failures == 0 ? 0 : 1;
}

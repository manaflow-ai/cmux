// Checks CEFShim/src/devtools_message_id.h (scripts/cmux-next/test-shim-devtools-id-cpp.sh):
// TopLevelDevToolsId, the top-level "id" of a DevTools protocol message
// without a full JSON parse, and the message of cmux_shim_devtools_call,
// whose parameters text goes in without a parse (IsDevToolsMethodName,
// IsOneJSONObject, DevToolsCallMessage).
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

static void Check(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

// A shim-internal call's message: the parameters text goes in as it is, in
// CEF's ExecuteDevToolsMethod format, and the message reads back with its id.
static void ExpectCallMessage(int id, const char* method, const std::string& params, const std::string& want) {
  const std::string got = cmux_shim::DevToolsCallMessage(id, method, params.data(), params.size());
  ++cases;
  long long read = -1;
  if (got != want || cmux_shim::TopLevelDevToolsId(got.data(), got.size(), &read) != DevToolsIdKind::kInt || read != id) {
    ++failures;
    std::fprintf(stderr, "FAIL call message %s: %s\n", method, got.c_str());
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
  // cmux_shim_devtools_call's checks and message (no parse of the parameters).
  using cmux_shim::IsDevToolsMethodName;
  using cmux_shim::IsOneJSONObject;
  Check(IsDevToolsMethodName("Runtime.evaluate"), "Runtime.evaluate is a method");
  Check(IsDevToolsMethodName("Emulation.setEmitTouchEventsForMouse"), "a long method name");
  Check(IsDevToolsMethodName("Target.attach_2.x"), "digits, '_' and two dots");
  Check(!IsDevToolsMethodName("Runtime"), "no dot");
  Check(!IsDevToolsMethodName(".evaluate") && !IsDevToolsMethodName("Runtime.") && !IsDevToolsMethodName("A..b"), "empty part");
  Check(!IsDevToolsMethodName("Runtime.evaluate\",\"params\":{}"), "a quote cannot reach the message");
  Check(!IsDevToolsMethodName("Runtime.eval uate") && !IsDevToolsMethodName("") && !IsDevToolsMethodName(nullptr), "space, empty, null");
  auto object = [](const std::string& text) { return IsOneJSONObject(text.data(), text.size()); };
  Check(object("{}") && object(" {\"a\":[1,{\"b\":\"}]\\\"\"}]} \n"), "objects, a brace and a quote inside a string");
  Check(!object("") && !object("[]") && !object("\"x\"") && !object("1"), "not an object");
  Check(!object("{\"a\":1") && !object("{\"a\":\"}") && !object("{} {}") && !object("{}x"), "unbalanced or trailing text");
  // A mismatched closer passes the scan (one bracket kind) but still ends at the text's end: it cannot close
  // the message's own object early, and Chromium's strict parse refuses the whole message.
  Check(object("{\"a\":1]"), "a mismatched closer is left to Chromium's parse");
  Check(!object("{\"a\":1]}") && !object("{\"a\":1]},\"id\":5}"), "a closer cannot end the object early and add keys");
  ExpectCallMessage(7, "Page.enable", "{}", R"({"id":7,"method":"Page.enable","params":{}})");
  ExpectCallMessage(9, "Page.getFrameTree", "", R"({"id":9,"method":"Page.getFrameTree"})");
  // Kept byte for byte: a lone surrogate escape and deep nesting (a full parse refuses both) and the key order.
  const std::string params = R"({"silent":true,"expression":"x(\ud800);[[[[]]]]","contextId":3})";
  ExpectCallMessage(1073741823, "Runtime.evaluate", params,
                    std::string(R"({"id":1073741823,"method":"Runtime.evaluate","params":)") + params + "}");
  std::string large = R"({"expression":")";
  large += std::string(3 << 20, 'a');
  large += R"("})";
  Check(object(large), "a 3 MB script's parameters are one object");
  ExpectCallMessage(12, "Runtime.evaluate", large, R"({"id":12,"method":"Runtime.evaluate","params":)" + large + "}");
  std::printf("%d cases, %d failures\n", cases, failures);
  return failures == 0 ? 0 : 1;
}

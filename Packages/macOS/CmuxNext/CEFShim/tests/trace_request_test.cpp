// Checks the request rules of the shim's Chromium tracing exports
// (CEFShim/src/trace_request.h, no CEF needed): the output path rule and the
// once-only completion that cmux_cef_begin_tracing and cmux_cef_end_tracing
// promise. Run: scripts/cmux-next/test-shim-tracing-cpp.sh
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "../src/trace_request.h"

using cmux_shim::OnceTraceReply;
using cmux_shim::TraceOutputPathAllowed;

static int failures = 0;
static int cases = 0;

static void Check(bool ok, const char* what) {
  ++cases;
  if (!ok) {
    ++failures;
    std::fprintf(stderr, "FAIL %s\n", what);
  }
}

static void ExpectPath(const char* path, bool allowed) {
  ++cases;
  if (TraceOutputPathAllowed(path) != allowed) {
    ++failures;
    std::fprintf(stderr, "FAIL path %s: expected %s\n", path ? path : "(null)", allowed ? "allowed" : "refused");
  }
}

struct Calls {
  std::vector<int> ints;
  std::vector<std::string> paths;  // "(null)" for a NULL path
};

static void RecordInt(void* context, int value) { static_cast<Calls*>(context)->ints.push_back(value); }

static void RecordPath(void* context, const char* path) {
  static_cast<Calls*>(context)->paths.push_back(path ? path : "(null)");
}

int main() {
  ExpectPath("/Users/me/Library/Caches/cmux/trace/chromium.json", true);
  ExpectPath("/t.json", true);
  ExpectPath(nullptr, false);
  ExpectPath("", false);
  ExpectPath("relative/chromium.json", false);
  ExpectPath("/tmp/chromium.pftrace", false);
  ExpectPath("/tmp/chromium.json.gz", false);
  ExpectPath("/tmp/.json", false);
  ExpectPath("/.json", false);
  ExpectPath("/tmp/", false);
  ExpectPath("/tmp/chromium.JSON", false);
  std::string longest = "/" + std::string(cmux_shim::kMaxTracePathBytes - 6, 'a') + ".json";
  ExpectPath(longest.c_str(), true);
  std::string too_long = "/" + std::string(cmux_shim::kMaxTracePathBytes - 5, 'a') + ".json";
  ExpectPath(too_long.c_str(), false);

  {  // An answered reply runs once, with the answer; dropping it adds nothing.
    Calls calls;
    {
      OnceTraceReply<int> reply(&RecordInt, &calls, 0);
      reply.Run(1);
      reply.Run(1);
    }
    Check(calls.ints == std::vector<int>{1}, "answered reply runs once with the answer");
  }
  {  // A dropped reply answers the fallback (CEF shut down before it answered).
    Calls calls;
    { OnceTraceReply<const char*> reply(&RecordPath, &calls, nullptr); }
    Check(calls.paths == std::vector<std::string>{"(null)"}, "dropped reply runs the fallback");
  }
  {  // A disarmed reply (the post failed, the call returned 0) never runs.
    Calls calls;
    {
      OnceTraceReply<int> reply(&RecordInt, &calls, 0);
      reply.Disarm();
      reply.Run(1);
    }
    Check(calls.ints.empty(), "disarmed reply never runs");
  }
  {  // Moving hands the duty to the new owner; the moved-from reply is silent.
    Calls calls;
    {
      OnceTraceReply<const char*> first(&RecordPath, &calls, nullptr);
      OnceTraceReply<const char*> second(std::move(first));
      second.Run("/tmp/chromium.json");
    }
    Check(calls.paths == std::vector<std::string>{"/tmp/chromium.json"}, "moved reply runs once, from its new owner");
  }
  {  // The task moves its reply into the CEF callback, which CEF drops unanswered.
    Calls calls;
    {
      OnceTraceReply<int> task_reply(&RecordInt, &calls, 0);
      { OnceTraceReply<int> callback_reply(std::move(task_reply)); }
      Check(calls.ints == std::vector<int>{0}, "callback dropped by CEF answers 0 at once");
    }
    Check(calls.ints == std::vector<int>{0}, "the task's moved-from reply adds nothing");
  }
  {  // A callback Chromium releases off the UI thread hands its reply to a task
     // (AnswerFallbackOnUI); the task answers the failure value once.
    Calls calls;
    {
      OnceTraceReply<const char*> callback_reply(&RecordPath, &calls, nullptr);
      Check(callback_reply.armed(), "an unanswered reply is armed");
      OnceTraceReply<const char*> task_reply(std::move(callback_reply));
      Check(!callback_reply.armed(), "the moved-from reply is not armed");
      task_reply.RunFallback();
      Check(!task_reply.armed(), "an answered reply is not armed");
    }
    Check(calls.paths == std::vector<std::string>{"(null)"}, "the posted fallback answers once");
  }
  {  // An answered reply ignores a later fallback.
    Calls calls;
    {
      OnceTraceReply<int> reply(&RecordInt, &calls, 0);
      reply.Run(1);
      reply.RunFallback();
    }
    Check(calls.ints == std::vector<int>{1}, "fallback after the answer adds nothing");
  }
  {  // No callback: nothing runs and nothing crashes.
    OnceTraceReply<int> reply(nullptr, nullptr, 0);
    reply.Run(1);
    Check(true, "null callback");
  }

  if (failures) {
    std::fprintf(stderr, "trace_request: %d/%d failed\n", failures, cases);
    return 1;
  }
  std::printf("trace_request: %d cases passed\n", cases);
  return 0;
}

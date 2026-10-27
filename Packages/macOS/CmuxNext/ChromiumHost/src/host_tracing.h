// Tracing in the Chromium Host (plans/cmux-next/chrome-parity/p09-observability.md,
// task 104 (c)). With the host on, Chromium's browser process is the host, so
// `trace.start chromium:true` (task 051) and the host's own recording ring run
// there: cmux sends TRACE_START, and the host starts its ring's recording and
// calls its shim's cmux_cef_begin_tracing (CEFShim/src/shim_tracing.mm, task
// 050); TRACE_STOP ends both and writes Chromium's JSON trace where cmux asks.
// Chrome's tracing service drives every process's TraceLog the same way, from
// one consumer over Mojo (services/tracing/public/mojom/perfetto_service.mojom,
// content/browser/tracing/tracing_controller_impl.cc).
//
// The ops are not in the generated table: they are versioned on their own, as
// kOpEnergySaver is (host_energy_saver.h).
//   TRACE_START  i32 version (kTraceWireVersion), i64 ring categories (the
//                recording's categories past the black box's, cmux_trace.h
//                CMUX_TRACE_CAT_*; 0: the ring does not record), str Chromium
//                categories (NULL: no Chromium tracing; "" CEF's default)
//                answered with i32 ring (1 recording), i32 chromium (1 every
//                Chromium process records, 0 refused or not asked)
//   TRACE_STOP   i32 version, i32 ring (1: stop the ring's recording), str
//                path (an absolute ".json" path; NULL: no Chromium trace)
//                answered with i32 ring (1 stopped), str the path Chromium
//                reported (NULL: none written)
// A later version only appends fields. A host lists kTracingHelloName in its
// HELLO; the remote shim's cmux_cef_begin_tracing refuses with no such host.
//
// Plain C++, no CEF: tests/host_tracing_test.cpp builds it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

// Next to kOpEnergySaver (host_energy_saver.h): not in the generated op table.
inline constexpr uint16_t kOpTraceStart = 0x800c;
inline constexpr uint16_t kOpTraceStop = 0x800d;
// The layout this side writes.
inline constexpr int32_t kTraceWireVersion = 1;
// The name a host lists in its HELLO when its shim has the tracing calls.
inline constexpr char kTracingHelloName[] = "cmux_host_tracing";
// The categories a recording adds to the black box's (cmux_trace.h
// CMUX_TRACE_CAT_RECORDING; host_black_box.h checks they agree): what the
// remote shim's cmux_cef_begin_tracing asks the host's ring for.
inline constexpr uint64_t kTraceRecordingCategories = 0xffe00;

// Where HostContext tells the black box of browser creations
// (cef.create_browser, an async slice from the create op to its
// AFTER_CREATED, keyed by cmux's minted id) and of the live browser count
// (the chromium_browser_count crash key). Main thread.
class HostTraceMarks {
 public:
  virtual ~HostTraceMarks() = default;
  virtual void CreateBegan(int32_t minted) = 0;
  virtual void Created(int32_t minted) = 0;
  virtual void BrowserCount(size_t count) = 0;
};

// TRACE_START's fields.
struct TraceStart {
  uint64_t ring_categories = 0;
  std::optional<std::string> chromium_categories;
  bool operator==(const TraceStart& other) const = default;
};

// TRACE_STOP's fields.
struct TraceStop {
  bool ring = false;
  std::optional<std::string> chromium_path;
  bool operator==(const TraceStop& other) const = default;
};

inline void WriteTraceStart(const TraceStart& start, control::TlvWriter* w) {
  w->I32(kTraceWireVersion);
  w->I64(static_cast<int64_t>(start.ring_categories));
  w->Str(start.chromium_categories ? start.chromium_categories->c_str() : nullptr);
}

inline void WriteTraceStop(const TraceStop& stop, control::TlvWriter* w) {
  w->I32(kTraceWireVersion);
  w->I32(stop.ring ? 1 : 0);
  w->Str(stop.chromium_path ? stop.chromium_path->c_str() : nullptr);
}

// nullopt for a malformed op: no version or one below 1, wrong types, version 1 with more fields.
inline std::optional<TraceStart> DecodeTraceStart(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  TraceStart start;
  start.ring_categories = static_cast<uint64_t>(r.I64());
  start.chromium_categories = r.Str();
  if (!r.ok() || version < 1) return std::nullopt;
  if (version == kTraceWireVersion && !r.AtEnd()) return std::nullopt;
  return start;
}

inline std::optional<TraceStop> DecodeTraceStop(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  const int32_t ring = r.I32();
  TraceStop stop;
  stop.chromium_path = r.Str();
  if (!r.ok() || version < 1 || (ring != 0 && ring != 1)) return std::nullopt;
  if (version == kTraceWireVersion && !r.AtEnd()) return std::nullopt;
  stop.ring = ring == 1;
  return stop;
}

// The answers, as the remote shim reads them.
struct TraceStartAnswer {
  bool ring = false;
  bool chromium = false;
};
struct TraceStopAnswer {
  bool ring = false;
  std::optional<std::string> path;
};

inline std::optional<TraceStartAnswer> DecodeTraceStartAnswer(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t ring = r.I32();
  const int32_t chromium = r.I32();
  if (!r.ok() || !r.AtEnd()) return std::nullopt;
  return TraceStartAnswer{ring == 1, chromium == 1};
}

inline std::optional<TraceStopAnswer> DecodeTraceStopAnswer(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t ring = r.I32();
  TraceStopAnswer answer;
  answer.path = r.Str();
  if (!r.ok() || !r.AtEnd()) return std::nullopt;
  answer.ring = ring == 1;
  return answer;
}

// The host's recording ring (host_black_box.h); a test passes its own. Both
// calls run on the host's files thread: the first start maps the ring.
class TraceRecorder {
 public:
  virtual ~TraceRecorder() = default;
  // Points every writer at the recording ring with the black box's categories
  // plus `categories`; false when it has no recording ring or one records.
  virtual bool StartRecording(uint64_t categories) = 0;
  // Back to the black box; false when none records.
  virtual bool StopRecording() = 0;
};

// TRACE_START and TRACE_STOP, which arrive on the host's main thread
// (Chromium's UI thread). The ring's part of each op runs on the files thread
// (`post_files`, a serial queue, so a stop's ring part runs after its start's),
// then Chromium's part on the main thread (`post_main`, in post order, so a
// begin goes before the end of the stop after it). Chromium answers a begin or
// an end once, on the UI thread or, while CEF shuts down, on another one
// (cmux_cef_shim.h): each answer goes to `answer` through `post_main`, so it
// always runs on the main thread, after the op's own turn.
class HostTracing {
 public:
  // cmux_cef_shim.h's cmux_cef_trace_started_fn, cmux_cef_trace_written_fn and
  // the two calls (the host passes its shim's; a test its own).
  using StartedFn = void (*)(void* ctx, int ok);
  using WrittenFn = void (*)(void* ctx, const char* path);
  using BeginFn = int (*)(const char* categories, StartedFn started, void* ctx);
  using EndFn = int (*)(const char* path, WrittenFn written, void* ctx);
  // The op's answer (HostContext::Reply).
  using Answer = std::function<void(uint32_t token, const control::TlvWriter& reply)>;
  // Runs a task on the main thread, in post order (browser_host_main.mm's PostToMain).
  using PostMain = void (*)(std::function<void()> task);
  // Runs a task on the files thread, in post order (browser_host_main.mm's PostToFiles).
  using PostFiles = void (*)(std::function<void()> task);

  HostTracing(BeginFn begin, EndFn end, TraceRecorder* recorder, Answer answer, PostMain post_main,
              PostFiles post_files)
      : begin_(begin),
        end_(end),
        recorder_(recorder),
        answer_(std::move(answer)),
        post_main_(post_main),
        post_files_(post_files) {}
  HostTracing(const HostTracing&) = delete;
  HostTracing& operator=(const HostTracing&) = delete;

  // Whether the host's HELLO lists kTracingHelloName: its shim has both calls.
  bool available() const { return begin_ != nullptr && end_ != nullptr; }

  // The answers of a host with no tracing (HostContext without a HostTracing).
  static void WriteRefusedStart(control::TlvWriter* reply) {
    reply->I32(0);
    reply->I32(0);
  }
  static void WriteRefusedStop(control::TlvWriter* reply) {
    reply->I32(0);
    reply->Str(nullptr);
  }

  // TRACE_START; false for a malformed op.
  bool Start(uint32_t token, const std::vector<control::Field>& fields) {
    std::optional<TraceStart> start = DecodeTraceStart(fields);
    if (!start) return false;
    post_files_([this, token, request = std::move(*start)] {
      const bool ring =
          request.ring_categories != 0 && recorder_ && recorder_->StartRecording(request.ring_categories);
      post_main_([this, token, ring, chromium = request.chromium_categories] { BeginChromium(token, ring, chromium); });
    });
    return true;
  }

  // TRACE_STOP; false for a malformed op.
  bool Stop(uint32_t token, const std::vector<control::Field>& fields) {
    std::optional<TraceStop> stop = DecodeTraceStop(fields);
    if (!stop) return false;
    post_files_([this, token, request = std::move(*stop)] {
      const bool ring = request.ring && recorder_ && recorder_->StopRecording();
      post_main_([this, token, ring, path = request.chromium_path] { EndChromium(token, ring, path); });
    });
    return true;
  }

 private:
  // A start's Chromium part, on the main thread once its ring part ran.
  void BeginChromium(uint32_t token, bool ring, const std::optional<std::string>& categories) {
    if (!categories || !begin_) return AnswerStart(token, ring, false);
    auto* pending = new Pending{this, token, ring};
    if (begin_(categories->c_str(), &HostTracing::Started, pending) != 1) {
      delete pending;  // nothing was posted: the callback never runs
      AnswerStart(token, ring, false);
    }
  }

  // A stop's Chromium part, on the main thread once its ring part ran.
  void EndChromium(uint32_t token, bool ring, const std::optional<std::string>& path) {
    if (!path || !end_) return AnswerStop(token, ring, std::nullopt);
    auto* pending = new Pending{this, token, ring};
    if (end_(path->c_str(), &HostTracing::Written, pending) != 1) {
      delete pending;
      AnswerStop(token, ring, std::nullopt);
    }
  }

  struct Pending {
    HostTracing* owner;
    uint32_t token;
    bool ring;
  };

  static void Started(void* ctx, int ok) {
    const Pending pending = *static_cast<Pending*>(ctx);
    delete static_cast<Pending*>(ctx);
    pending.owner->post_main_([pending, ok] { pending.owner->AnswerStart(pending.token, pending.ring, ok == 1); });
  }

  static void Written(void* ctx, const char* path) {
    const Pending pending = *static_cast<Pending*>(ctx);
    delete static_cast<Pending*>(ctx);
    // The path is valid only during this call.
    std::optional<std::string> written = path ? std::optional<std::string>(path) : std::nullopt;
    pending.owner->post_main_([pending, written = std::move(written)] {
      pending.owner->AnswerStop(pending.token, pending.ring, written);
    });
  }

  void AnswerStart(uint32_t token, bool ring, bool chromium) {
    control::TlvWriter reply;
    reply.I32(ring ? 1 : 0);
    reply.I32(chromium ? 1 : 0);
    answer_(token, reply);
  }

  void AnswerStop(uint32_t token, bool ring, const std::optional<std::string>& path) {
    control::TlvWriter reply;
    reply.I32(ring ? 1 : 0);
    reply.Str(path ? path->c_str() : nullptr);
    answer_(token, reply);
  }

  const BeginFn begin_;
  const EndFn end_;
  TraceRecorder* const recorder_;
  const Answer answer_;
  const PostMain post_main_;
  const PostFiles post_files_;
};

}  // namespace cmux_host

// Chromium tracing for cmux (cmux_cef_begin_tracing, cmux_cef_end_tracing,
// cmux_cef_now_trace_us) over stock CEF (include/cef_trace.h), with no fork
// API. CefBeginTracing and CefEndTracing run on the browser UI thread only,
// like content::TracingController in Chrome
// (content/public/browser/tracing_controller.h), so every call posts there.
// The argument and completion rules live in trace_request.h
// (CEFShim/tests/trace_request_test.cpp).

#include <string>
#include <utility>

#include "cmux_cef_shim.h"  // Sources/CmuxNextBrowser/CEF/Shim
#include "include/cef_callback.h"
#include "include/cef_task.h"
#include "include/cef_trace.h"
#include "trace_request.h"

namespace cmux_shim {

namespace {

using StartedReply = OnceTraceReply<int>;
using WrittenReply = OnceTraceReply<const char*>;

template <typename Arg>
class FallbackOnUI : public CefTask {
 public:
  explicit FallbackOnUI(OnceTraceReply<Arg> reply) : reply_(std::move(reply)) {}
  void Execute() override { reply_.RunFallback(); }

 private:
  OnceTraceReply<Arg> reply_;
  IMPLEMENT_REFCOUNTING(FallbackOnUI);
};

// An unanswered CEF callback answers its failure value on the UI thread, like
// its answer. Chromium can release one elsewhere: FileTraceDataEndpoint's
// CloseOnBlockingThread returns on a failed base::ReplaceFile without posting
// FinalizeOnUIThread, so the end callback dies on a ThreadPool thread
// (content/browser/tracing/tracing_controller_impl_data_endpoint.cc). When the
// post fails (CEF shut down), the task drops here and its reply answers inline.
template <typename Arg>
void AnswerFallbackOnUI(OnceTraceReply<Arg>& reply) {
  if (!reply.armed()) return;
  if (CefCurrentlyOn(TID_UI)) {
    reply.RunFallback();
    return;
  }
  CefRefPtr<CefTask> task = new FallbackOnUI<Arg>(std::move(reply));
  CefPostTask(TID_UI, task);
}

class TraceStarted : public CefCompletionCallback {
 public:
  explicit TraceStarted(StartedReply reply) : reply_(std::move(reply)) {}
  ~TraceStarted() override { AnswerFallbackOnUI(reply_); }
  void OnComplete() override { reply_.Run(1); }

 private:
  StartedReply reply_;
  IMPLEMENT_REFCOUNTING(TraceStarted);
};

class TraceWritten : public CefEndTracingCallback {
 public:
  explicit TraceWritten(WrittenReply reply) : reply_(std::move(reply)) {}
  ~TraceWritten() override { AnswerFallbackOnUI(reply_); }
  void OnEndTracingComplete(const CefString& tracing_file) override {
    const std::string path = tracing_file.ToString();
    reply_.Run(path.c_str());
  }

 private:
  WrittenReply reply_;
  IMPLEMENT_REFCOUNTING(TraceWritten);
};

// In both tasks, a request CEF refuses drops its callback object at once, and
// that object's reply then answers with the failure value (AnswerFallbackOnUI).
class BeginTracingTask : public CefTask {
 public:
  BeginTracingTask(std::string categories, StartedReply reply)
      : categories_(std::move(categories)), reply_(std::move(reply)) {}
  void Execute() override { CefBeginTracing(categories_, new TraceStarted(std::move(reply_))); }
  void Disarm() { reply_.Disarm(); }

 private:
  std::string categories_;
  StartedReply reply_;
  IMPLEMENT_REFCOUNTING(BeginTracingTask);
};

class EndTracingTask : public CefTask {
 public:
  EndTracingTask(std::string path, WrittenReply reply) : path_(std::move(path)), reply_(std::move(reply)) {}
  void Execute() override { CefEndTracing(path_, new TraceWritten(std::move(reply_))); }
  void Disarm() { reply_.Disarm(); }

 private:
  std::string path_;
  WrittenReply reply_;
  IMPLEMENT_REFCOUNTING(EndTracingTask);
};

// 1 when posted. When CEF has no UI thread (not initialized, or shut down),
// the task is never run and its completion must not run either.
template <typename Task>
int PostToUI(CefRefPtr<Task> task) {
  if (CefPostTask(TID_UI, task.get())) return 1;
  task->Disarm();
  return 0;
}

}  // namespace

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_cef_begin_tracing(const char* categories, cmux_cef_trace_started_fn started, void* ctx) {
  CefRefPtr<BeginTracingTask> task =
      new BeginTracingTask(categories ? categories : "", StartedReply(started, ctx, 0));
  return PostToUI(task);
}

int cmux_cef_end_tracing(const char* path, cmux_cef_trace_written_fn written, void* ctx) {
  if (!TraceOutputPathAllowed(path)) return 0;
  CefRefPtr<EndTracingTask> task = new EndTracingTask(path, WrittenReply(written, ctx, nullptr));
  return PostToUI(task);
}

int64_t cmux_cef_now_trace_us(void) {
  return CefNowFromSystemTraceTime();
}

}  // extern "C"

// Request rules of the shim's Chromium tracing exports (shim_tracing.mm), with
// no CEF (CEFShim/tests/trace_request_test.cpp).
#pragma once

#include <cstddef>
#include <string_view>
#include <utility>

namespace cmux_shim {

// The longest output path cmux_cef_end_tracing accepts, terminator excluded
// (macOS PATH_MAX is 1024 with the terminator).
inline constexpr size_t kMaxTracePathBytes = 1023;

// The output of cmux_cef_end_tracing: an absolute path that ends in ".json"
// and names a file, not only the suffix. CEF writes to a temporary file for an
// empty path; the caller always names its recording directory instead.
inline bool TraceOutputPathAllowed(const char* c_path) {
  constexpr std::string_view kSuffix = ".json";
  if (c_path == nullptr) return false;
  const std::string_view path(c_path);
  if (!path.starts_with('/')) return false;
  if (path.size() > kMaxTracePathBytes || path.size() <= kSuffix.size() + 1) return false;
  if (path[path.size() - kSuffix.size() - 1] == '/') return false;
  return path.ends_with(kSuffix);
}

// A C completion that runs exactly once: with the answer, or with `fallback`
// when its owner drops it unanswered. Chrome does the same for Mojo replies
// (mojo/public/cpp/bindings/callback_helpers.h,
// WrapCallbackWithDefaultInvokeIfNotRun). Move-only: one owner at a time.
template <typename Arg>
class OnceTraceReply {
 public:
  using Fn = void (*)(void* context, Arg value);

  OnceTraceReply(Fn fn, void* context, Arg fallback) : fn_(fn), context_(context), fallback_(fallback) {}
  OnceTraceReply(OnceTraceReply&& other) noexcept
      : fn_(std::exchange(other.fn_, nullptr)), context_(other.context_), fallback_(other.fallback_) {}
  OnceTraceReply(const OnceTraceReply&) = delete;
  OnceTraceReply& operator=(const OnceTraceReply&) = delete;
  OnceTraceReply& operator=(OnceTraceReply&&) = delete;
  ~OnceTraceReply() { Run(fallback_); }

  void Run(Arg value) {
    if (Fn fn = std::exchange(fn_, nullptr)) fn(context_, value);
  }
  void RunFallback() { Run(fallback_); }
  bool armed() const { return fn_ != nullptr; }
  // The request was never sent: the caller learns that from the return value,
  // so the completion must not run.
  void Disarm() { fn_ = nullptr; }

 private:
  Fn fn_;
  void* context_;
  Arg fallback_;
};

}  // namespace cmux_shim

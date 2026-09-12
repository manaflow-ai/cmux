// Copyright (c) 2014 Marshall A. Greenblatt. Portions copyright (c) 2012
// Google Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

///
/// \file
/// A bunch of macros for logging.
///
/// NOTE: The contents of this file are only available to applications that link
/// against the libcef_dll_wrapper target.
///
/// WARNING: Logging macros should not be used in the main/browser process
/// before calling CefInitialize or in sub-processes before calling
/// CefExecuteProcess.
///
/// INSTRUCTIONS:
///
/// The way to log things is to stream things to LOG(<a particular severity
/// level>). E.g.,
///
/// <pre>
///   LOG(INFO) << "Found " << num_cookies << " cookies";
/// </pre>
///
/// You can also do conditional logging:
///
/// <pre>
///   LOG_IF(INFO, num_cookies > 10) << "Got lots of cookies";
/// </pre>
///
/// The CHECK(condition) macro is active in both debug and release builds and
/// effectively performs a LOG(FATAL) which terminates the process and
/// generates a crashdump unless a debugger is attached.
///
/// There are also "debug mode" logging macros like the ones above:
///
/// <pre>
///   DLOG(INFO) << "Found cookies";
///
///   DLOG_IF(INFO, num_cookies > 10) << "Got lots of cookies";
/// </pre>
///
/// All "debug mode" logging is compiled away to nothing for non-debug mode
/// compiles.  LOG_IF and development flags also work well together
/// because the code can be compiled away sometimes.
///
/// We also have
///
/// <pre>
///   LOG_ASSERT(assertion);
///   DLOG_ASSERT(assertion);
/// </pre>
///
/// which is syntactic sugar for "{,D}LOG_IF(FATAL, assert fails) << assertion;"
///
/// There are "verbose level" logging macros.  They look like
///
/// <pre>
///   VLOG(1) << "I'm printed when you run the program with --v=1 or more";
///   VLOG(2) << "I'm printed when you run the program with --v=2 or more";
/// </pre>
///
/// These always log at the INFO log level (when they log at all).
/// The verbose logging can also be turned on module-by-module.  For instance,
/// <pre>
///    --vmodule=profile=2,icon_loader=1,browser_*=3,*/chromeos/*=4 --v=0
/// </pre>
/// will cause:
/// 1. VLOG(2) and lower messages to be printed from profile.{h,cc}
/// 2. VLOG(1) and lower messages to be printed from icon_loader.{h,cc}
/// 3. VLOG(3) and lower messages to be printed from files prefixed with
///    "browser"
/// 4. VLOG(4) and lower messages to be printed from files under a
///    "chromeos" directory.
/// 5. VLOG(0) and lower messages to be printed from elsewhere
///
/// The wildcarding functionality shown by (c) supports both '*' (match
/// 0 or more characters) and '?' (match any single character)
/// wildcards.  Any pattern containing a forward or backward slash will
/// be tested against the whole pathname and not just the module.
/// E.g., "*/foo/bar/*=2" would change the logging level for all code
/// in source files under a "foo/bar" directory.
///
/// There's also VLOG_IS_ON(n) "verbose level" condition macro. To be used as
///
/// <pre>
///   if (VLOG_IS_ON(2)) {
///     // do some logging preparation and logging
///     // that can't be accomplished with just VLOG(2) << ...;
///   }
/// </pre>
///
/// There is also a VLOG_IF "verbose level" condition macro for sample
/// cases, when some extra computation and preparation for logs is not
/// needed.
///
/// <pre>
///   VLOG_IF(1, (size > 1024))
///      << "I'm printed when size is more than 1024 and when you run the "
///         "program with --v=1 or more";
/// </pre>
///
/// We also override the standard 'assert' to use 'DLOG_ASSERT'.
///
/// Lastly, there is:
///
/// <pre>
///   PLOG(ERROR) << "Couldn't do foo";
///   DPLOG(ERROR) << "Couldn't do foo";
///   PLOG_IF(ERROR, cond) << "Couldn't do foo";
///   DPLOG_IF(ERROR, cond) << "Couldn't do foo";
///   PCHECK(condition) << "Couldn't do foo";
///   DPCHECK(condition) << "Couldn't do foo";
/// </pre>
///
/// which append the last system error to the message in string form (taken from
/// GetLastError() on Windows and errno on POSIX).
///
/// The supported severity levels for macros that allow you to specify one
/// are (in increasing order of severity) INFO, WARNING, ERROR, and FATAL.
///
/// Very important: logging a message at the FATAL severity level causes
/// the program to terminate (after the message is logged).
///
/// There is the special severity of DFATAL, which logs FATAL in debug mode,
/// ERROR in normal mode.
///

#ifndef CEF_INCLUDE_BASE_CEF_LOGGING_H_
#define CEF_INCLUDE_BASE_CEF_LOGGING_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/logging.h"
#include "base/notreached.h"
#elif defined(DCHECK)
// Do nothing if the macros provided by this header already exist.
// This can happen in cases where Chromium code is used directly by the
// client application. When using Chromium code directly always include
// the Chromium header first to avoid type conflicts.

// Always define the DCHECK_IS_ON macro which is used from other CEF headers.
#if defined(NDEBUG) && !defined(DCHECK_ALWAYS_ON)
#define DCHECK_IS_ON() false
#else
#define DCHECK_IS_ON() true
#endif

#else  // !defined(DCHECK)
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include <cassert>
#include <cstring>
#include <sstream>
#include <string>
#include <string_view>

#include "include/base/cef_build.h"
#include "include/internal/cef_logging_internal.h"

namespace cef {
namespace logging {

class ScopedEarlySupport;

namespace internal {

// Structure defining the baseline logging implementation used by client
// and wrapper code that links libcef_dll_wrapper.
struct Implementation {
  decltype(&cef_get_min_log_level) get_min_log_level;
  decltype(&cef_get_vlog_level) get_vlog_level;
  decltype(&cef_log) log;
};

// Returns the currently configured logging implementation.
const Implementation* GetImplementation();

// Change the logging implementation for the lifespan of this scoped object.
// See ScopedEarlySupport for usage.
class ScopedImplementation {
 public:
  ScopedImplementation(const ScopedImplementation&) = delete;
  ScopedImplementation& operator=(const ScopedImplementation&) = delete;

 private:
  friend class logging::ScopedEarlySupport;

  ScopedImplementation();
  ~ScopedImplementation();
  void Init(const Implementation* impl);

  const Implementation* previous_ = nullptr;
};

}  // namespace internal

// Gets the current log level.
inline int GetMinLogLevel() {
  return internal::GetImplementation()->get_min_log_level();
}

// Gets the current vlog level for the given file (usually taken from
// __FILE__). Note that |N| is the size *with* the null terminator.
template <size_t N>
int GetVlogLevel(const char (&file)[N]) {
  return internal::GetImplementation()->get_vlog_level(file, N);
}

typedef int LogSeverity;
const LogSeverity LOG_VERBOSE = -1;  // This is level 1 verbosity
// Note: the log severities are used to index into the array of names,
// see log_severity_names.
const LogSeverity LOG_INFO = 0;
const LogSeverity LOG_WARNING = 1;
const LogSeverity LOG_ERROR = 2;
const LogSeverity LOG_FATAL = 3;
const LogSeverity LOG_NUM_SEVERITIES = 4;

// LOG_DFATAL is LOG_FATAL in debug mode, ERROR in normal mode
#ifdef NDEBUG
const LogSeverity LOG_DFATAL = LOG_ERROR;
#else
const LogSeverity LOG_DFATAL = LOG_FATAL;
#endif

///
/// Support the use of CEF logging macros during early application startup,
/// prior to loading libcef. Not for use during or after CEF initialization.
/// Support is scoped to this object's lifespan. This implementation is not
/// thread-safe and should not be used for logging from multiple threads.
///
class ScopedEarlySupport final : public internal::ScopedImplementation {
 public:
  ///
  /// Logging configuration.
  ///
  struct Config {
    ///
    /// Configure logging level.
    ///
    int min_log_level = LOG_ERROR;
    int vlog_level = 0;

    ///
    /// Configure log line formatting.
    ///
    const char* log_prefix = nullptr;
    bool log_process_id = true;
    bool log_thread_id = true;
    bool log_timestamp = true;
    bool log_tickcount = true;

    ///
    /// Optionally override the default handling of formatted log lines. For
    /// example, this callback could be used to write |log_line| to a file.
    /// Return false to proceed with the default behavior of writing to stderr
    /// or debugger console. FATAL errors will still intentionally crash the
    /// application.
    ///
    bool (*formatted_log_handler)(const char* /*log_line*/) = nullptr;
  };

  explicit ScopedEarlySupport(const Config& config);

  ScopedEarlySupport(const ScopedEarlySupport&) = delete;
  ScopedEarlySupport& operator=(const ScopedEarlySupport&) = delete;

 private:
  static const Config& GetConfig();

  static int get_min_log_level();
  static int get_vlog_level(const char* file_start, size_t N);
  static void log(const char* file,
                  int line,
                  int severity,
                  const char* message);

  const struct Impl {
    internal::Implementation ptrs;
    Config config;
  } impl_;
};

// A few definitions of macros that don't generate much code. These are used
// by LOG() and LOG_IF, etc. Since these are used all over our code, it's
// better to have compact code for these operations.
#define COMPACT_GOOGLE_LOG_EX_INFO(ClassName, ...)                        \
  ::cef::logging::ClassName(__FILE__, __LINE__, ::cef::logging::LOG_INFO, \
                            ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_EX_WARNING(ClassName, ...)                        \
  ::cef::logging::ClassName(__FILE__, __LINE__, ::cef::logging::LOG_WARNING, \
                            ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_EX_ERROR(ClassName, ...)                        \
  ::cef::logging::ClassName(__FILE__, __LINE__, ::cef::logging::LOG_ERROR, \
                            ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_EX_FATAL(ClassName, ...)                        \
  ::cef::logging::ClassName(__FILE__, __LINE__, ::cef::logging::LOG_FATAL, \
                            ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_EX_DFATAL(ClassName, ...)                        \
  ::cef::logging::ClassName(__FILE__, __LINE__, ::cef::logging::LOG_DFATAL, \
                            ##__VA_ARGS__)

#define COMPACT_GOOGLE_LOG_INFO COMPACT_GOOGLE_LOG_EX_INFO(LogMessage)
#define COMPACT_GOOGLE_LOG_WARNING COMPACT_GOOGLE_LOG_EX_WARNING(LogMessage)
#define COMPACT_GOOGLE_LOG_ERROR COMPACT_GOOGLE_LOG_EX_ERROR(LogMessage)
#define COMPACT_GOOGLE_LOG_FATAL COMPACT_GOOGLE_LOG_EX_FATAL(LogMessage)
#define COMPACT_GOOGLE_LOG_DFATAL COMPACT_GOOGLE_LOG_EX_DFATAL(LogMessage)

#if defined(OS_WIN)
// wingdi.h defines ERROR to be 0. When we call LOG(ERROR), it gets
// substituted with 0, and it expands to COMPACT_GOOGLE_LOG_0. To allow us
// to keep using this syntax, we define this macro to do the same thing
// as COMPACT_GOOGLE_LOG_ERROR, and also define ERROR the same way that
// the Windows SDK does for consistency.
#define ERROR 0
#define COMPACT_GOOGLE_LOG_EX_0(ClassName, ...) \
  COMPACT_GOOGLE_LOG_EX_ERROR(ClassName, ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_0 COMPACT_GOOGLE_LOG_ERROR
// Needed for LOG_IS_ON(ERROR).
const LogSeverity LOG_0 = LOG_ERROR;
#endif

// As special cases, we can assume that LOG_IS_ON(FATAL) always holds. Also,
// LOG_IS_ON(DFATAL) always holds in debug mode. In particular, CHECK()s will
// always fire if they fail.
#define LOG_IS_ON(severity) \
  ((::cef::logging::LOG_##severity) >= ::cef::logging::GetMinLogLevel())

// We can't do any caching tricks with VLOG_IS_ON() like the
// google-glog version since it requires GCC extensions.  This means
// that using the v-logging functions in conjunction with --vmodule
// may be slow.
#define VLOG_IS_ON(verboselevel) \
  ((verboselevel) <= ::cef::logging::GetVlogLevel(__FILE__))

// Helper macro which avoids evaluating the arguments to a stream if
// the condition doesn't hold.
#define LAZY_STREAM(stream, condition) \
  !(condition) ? (void)0 : ::cef::logging::LogMessageVoidify() & (stream)

// We use the preprocessor's merging operator, "##", so that, e.g.,
// LOG(INFO) becomes the token COMPACT_GOOGLE_LOG_INFO.  There's some funny
// subtle difference between ostream member streaming functions (e.g.,
// ostream::operator<<(int) and ostream non-member streaming functions
// (e.g., ::operator<<(ostream&, string&): it turns out that it's
// impossible to stream something like a string directly to an unnamed
// ostream. We employ a neat hack by calling the stream() member
// function of LogMessage which seems to avoid the problem.
#define LOG_STREAM(severity) COMPACT_GOOGLE_LOG_##severity.stream()

#define LOG(severity) LAZY_STREAM(LOG_STREAM(severity), LOG_IS_ON(severity))
#define LOG_IF(severity, condition) \
  LAZY_STREAM(LOG_STREAM(severity), LOG_IS_ON(severity) && (condition))

#define SYSLOG(severity) LOG(severity)
#define SYSLOG_IF(severity, condition) LOG_IF(severity, condition)

// The VLOG macros log with negative verbosities.
#define VLOG_STREAM(verbose_level) \
  cef::logging::LogMessage(__FILE__, __LINE__, -verbose_level).stream()

#define VLOG(verbose_level) \
  LAZY_STREAM(VLOG_STREAM(verbose_level), VLOG_IS_ON(verbose_level))

#define VLOG_IF(verbose_level, condition) \
  LAZY_STREAM(VLOG_STREAM(verbose_level), \
              VLOG_IS_ON(verbose_level) && (condition))

#if defined(OS_WIN)
#define VPLOG_STREAM(verbose_level)                                            \
  cef::logging::Win32ErrorLogMessage(__FILE__, __LINE__, -verbose_level,       \
                                     ::cef::logging::GetLastSystemErrorCode()) \
      .stream()
#elif defined(OS_POSIX)
#define VPLOG_STREAM(verbose_level)                                       \
  cef::logging::ErrnoLogMessage(__FILE__, __LINE__, -verbose_level,       \
                                ::cef::logging::GetLastSystemErrorCode()) \
      .stream()
#endif

#define VPLOG(verbose_level) \
  LAZY_STREAM(VPLOG_STREAM(verbose_level), VLOG_IS_ON(verbose_level))

#define VPLOG_IF(verbose_level, condition) \
  LAZY_STREAM(VPLOG_STREAM(verbose_level), \
              VLOG_IS_ON(verbose_level) && (condition))

// TODO(akalin): Add more VLOG variants, e.g. VPLOG.

#define LOG_ASSERT(condition) \
  LOG_IF(FATAL, !(condition)) << "Assert failed: " #condition ". "
#define SYSLOG_ASSERT(condition) \
  SYSLOG_IF(FATAL, !(condition)) << "Assert failed: " #condition ". "

#if defined(OS_WIN)
#define PLOG_STREAM(severity)                                                \
  COMPACT_GOOGLE_LOG_EX_##severity(Win32ErrorLogMessage,                     \
                                   ::cef::logging::GetLastSystemErrorCode()) \
      .stream()
#elif defined(OS_POSIX)
#define PLOG_STREAM(severity)                                                \
  COMPACT_GOOGLE_LOG_EX_##severity(ErrnoLogMessage,                          \
                                   ::cef::logging::GetLastSystemErrorCode()) \
      .stream()
#endif

#define PLOG(severity) LAZY_STREAM(PLOG_STREAM(severity), LOG_IS_ON(severity))

#define PLOG_IF(severity, condition) \
  LAZY_STREAM(PLOG_STREAM(severity), LOG_IS_ON(severity) && (condition))

// The actual stream used isn't important.
#define EAT_STREAM_PARAMETERS \
  true ? (void)0 : ::cef::logging::LogMessageVoidify() & LOG_STREAM(FATAL)

// CHECK dies with a fatal error if condition is not true.  It is *not*
// controlled by NDEBUG, so the check will be executed regardless of
// compilation mode.
//
// We make sure CHECK et al. always evaluates their arguments, as
// doing CHECK(FunctionWithSideEffect()) is a common idiom.

#define CHECK(condition)                       \
  LAZY_STREAM(LOG_STREAM(FATAL), !(condition)) \
      << "Check failed: " #condition ". "

#define PCHECK(condition)                       \
  LAZY_STREAM(PLOG_STREAM(FATAL), !(condition)) \
      << "Check failed: " #condition ". "

// Helper macro for binary operators.
// Don't use this macro directly in your code, use CHECK_EQ et al below.
//
// TODO(akalin): Rewrite this so that constructs like if (...)
// CHECK_EQ(...) else { ... } work properly.
#define CHECK_OP(name, op, val1, val2)                        \
  if (std::string* _result = cef::logging::Check##name##Impl( \
          (val1), (val2), #val1 " " #op " " #val2))           \
  cef::logging::LogMessage(__FILE__, __LINE__, _result).stream()

// Build the error message string.  This is separate from the "Impl"
// function template because it is not performance critical and so can
// be out of line, while the "Impl" code should be inline.  Caller
// takes ownership of the returned string.
template <class t1, class t2>
std::string* MakeCheckOpString(const t1& v1, const t2& v2, const char* names) {
  std::ostringstream ss;
  ss << names << " (" << v1 << " vs. " << v2 << ")";
  std::string* msg = new std::string(ss.str());
  return msg;
}

// MSVC doesn't like complex extern templates and DLLs.
#if !defined(COMPILER_MSVC)
// Commonly used instantiations of MakeCheckOpString<>. Explicitly instantiated
// in logging.cc.
extern template std::string* MakeCheckOpString<int, int>(const int&,
                                                         const int&,
                                                         const char* names);
extern template std::string* MakeCheckOpString<unsigned long, unsigned long>(
    const unsigned long&,
    const unsigned long&,
    const char* names);
extern template std::string* MakeCheckOpString<unsigned long, unsigned int>(
    const unsigned long&,
    const unsigned int&,
    const char* names);
extern template std::string* MakeCheckOpString<unsigned int, unsigned long>(
    const unsigned int&,
    const unsigned long&,
    const char* names);
extern template std::string* MakeCheckOpString<std::string, std::string>(
    const std::string&,
    const std::string&,
    const char* name);
#endif

// Helper functions for CHECK_OP macro.
// The (int, int) specialization works around the issue that the compiler
// will not instantiate the template version of the function on values of
// unnamed enum type - see comment below.
#define DEFINE_CHECK_OP_IMPL(name, op)                                       \
  template <class t1, class t2>                                              \
  inline std::string* Check##name##Impl(const t1& v1, const t2& v2,          \
                                        const char* names) {                 \
    if (v1 op v2)                                                            \
      return NULL;                                                           \
    else                                                                     \
      return MakeCheckOpString(v1, v2, names);                               \
  }                                                                          \
  inline std::string* Check##name##Impl(int v1, int v2, const char* names) { \
    if (v1 op v2)                                                            \
      return NULL;                                                           \
    else                                                                     \
      return MakeCheckOpString(v1, v2, names);                               \
  }
DEFINE_CHECK_OP_IMPL(EQ, ==)
DEFINE_CHECK_OP_IMPL(NE, !=)
DEFINE_CHECK_OP_IMPL(LE, <=)
DEFINE_CHECK_OP_IMPL(LT, <)
DEFINE_CHECK_OP_IMPL(GE, >=)
DEFINE_CHECK_OP_IMPL(GT, >)
#undef DEFINE_CHECK_OP_IMPL

#define CHECK_EQ(val1, val2) CHECK_OP(EQ, ==, val1, val2)
#define CHECK_NE(val1, val2) CHECK_OP(NE, !=, val1, val2)
#define CHECK_LE(val1, val2) CHECK_OP(LE, <=, val1, val2)
#define CHECK_LT(val1, val2) CHECK_OP(LT, <, val1, val2)
#define CHECK_GE(val1, val2) CHECK_OP(GE, >=, val1, val2)
#define CHECK_GT(val1, val2) CHECK_OP(GT, >, val1, val2)

#if defined(NDEBUG)
#define ENABLE_DLOG 0
#else
#define ENABLE_DLOG 1
#endif

#if defined(NDEBUG) && !defined(DCHECK_ALWAYS_ON)
#define DCHECK_IS_ON() 0
#else
#define DCHECK_IS_ON() 1
#endif

// Definitions for DLOG et al.

#if ENABLE_DLOG

#define DLOG_IS_ON(severity) LOG_IS_ON(severity)
#define DLOG_IF(severity, condition) LOG_IF(severity, condition)
#define DLOG_ASSERT(condition) LOG_ASSERT(condition)
#define DPLOG_IF(severity, condition) PLOG_IF(severity, condition)
#define DVLOG_IF(verboselevel, condition) VLOG_IF(verboselevel, condition)
#define DVPLOG_IF(verboselevel, condition) VPLOG_IF(verboselevel, condition)

#else  // ENABLE_DLOG

// If ENABLE_DLOG is off, we want to avoid emitting any references to
// |condition| (which may reference a variable defined only if NDEBUG
// is not defined).  Contrast this with DCHECK et al., which has
// different behavior.

#define DLOG_IS_ON(severity) false
#define DLOG_IF(severity, condition) EAT_STREAM_PARAMETERS
#define DLOG_ASSERT(condition) EAT_STREAM_PARAMETERS
#define DPLOG_IF(severity, condition) EAT_STREAM_PARAMETERS
#define DVLOG_IF(verboselevel, condition) EAT_STREAM_PARAMETERS
#define DVPLOG_IF(verboselevel, condition) EAT_STREAM_PARAMETERS

#endif  // ENABLE_DLOG

// DEBUG_MODE is for uses like
//   if (DEBUG_MODE) foo.CheckThatFoo();
// instead of
//   #ifndef NDEBUG
//     foo.CheckThatFoo();
//   #endif
//
// We tie its state to ENABLE_DLOG.
enum { DEBUG_MODE = ENABLE_DLOG };

#undef ENABLE_DLOG

#define DLOG(severity) LAZY_STREAM(LOG_STREAM(severity), DLOG_IS_ON(severity))

#define DPLOG(severity) LAZY_STREAM(PLOG_STREAM(severity), DLOG_IS_ON(severity))

#define DVLOG(verboselevel) DVLOG_IF(verboselevel, VLOG_IS_ON(verboselevel))

#define DVPLOG(verboselevel) DVPLOG_IF(verboselevel, VLOG_IS_ON(verboselevel))

// Definitions for DCHECK et al.

#if DCHECK_IS_ON()

#define COMPACT_GOOGLE_LOG_EX_DCHECK(ClassName, ...) \
  COMPACT_GOOGLE_LOG_EX_FATAL(ClassName, ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_DCHECK COMPACT_GOOGLE_LOG_FATAL
const LogSeverity LOG_DCHECK = LOG_FATAL;

#else  // DCHECK_IS_ON()

// These are just dummy values.
#define COMPACT_GOOGLE_LOG_EX_DCHECK(ClassName, ...) \
  COMPACT_GOOGLE_LOG_EX_INFO(ClassName, ##__VA_ARGS__)
#define COMPACT_GOOGLE_LOG_DCHECK COMPACT_GOOGLE_LOG_INFO
const LogSeverity LOG_DCHECK = LOG_INFO;

#endif  // DCHECK_IS_ON()

// DCHECK et al. make sure to reference |condition| regardless of
// whether DCHECKs are enabled; this is so that we don't get unused
// variable warnings if the only use of a variable is in a DCHECK.
// This behavior is different from DLOG_IF et al.

#define DCHECK(condition)                                         \
  LAZY_STREAM(LOG_STREAM(DCHECK), DCHECK_IS_ON() && !(condition)) \
      << "Check failed: " #condition ". "

#define DPCHECK(condition)                                         \
  LAZY_STREAM(PLOG_STREAM(DCHECK), DCHECK_IS_ON() && !(condition)) \
      << "Check failed: " #condition ". "

// Helper macro for binary operators.
// Don't use this macro directly in your code, use DCHECK_EQ et al below.
#define DCHECK_OP(name, op, val1, val2)                                    \
  if (DCHECK_IS_ON())                                                      \
    if (std::string* _result = cef::logging::Check##name##Impl(            \
            (val1), (val2), #val1 " " #op " " #val2))                      \
  cef::logging::LogMessage(__FILE__, __LINE__, ::cef::logging::LOG_DCHECK, \
                           _result)                                        \
      .stream()

// Equality/Inequality checks - compare two values, and log a
// LOG_DCHECK message including the two values when the result is not
// as expected.  The values must have operator<<(ostream, ...)
// defined.
//
// You may append to the error message like so:
//   DCHECK_NE(1, 2) << ": The world must be ending!";
//
// We are very careful to ensure that each argument is evaluated exactly
// once, and that anything which is legal to pass as a function argument is
// legal here.  In particular, the arguments may be temporary expressions
// which will end up being destroyed at the end of the apparent statement,
// for example:
//   DCHECK_EQ(string("abc")[1], 'b');
//
// WARNING: These may not compile correctly if one of the arguments is a pointer
// and the other is NULL. To work around this, simply static_cast NULL to the
// type of the desired pointer.

#define DCHECK_EQ(val1, val2) DCHECK_OP(EQ, ==, val1, val2)
#define DCHECK_NE(val1, val2) DCHECK_OP(NE, !=, val1, val2)
#define DCHECK_LE(val1, val2) DCHECK_OP(LE, <=, val1, val2)
#define DCHECK_LT(val1, val2) DCHECK_OP(LT, <, val1, val2)
#define DCHECK_GE(val1, val2) DCHECK_OP(GE, >=, val1, val2)
#define DCHECK_GT(val1, val2) DCHECK_OP(GT, >, val1, val2)

#define NOTREACHED() DCHECK(false)

// Redefine the standard assert to use our nice log files
#undef assert
#define assert(x) DLOG_ASSERT(x)

// This class more or less represents a particular log message.  You
// create an instance of LogMessage and then stream stuff to it.
// When you finish streaming to it, ~LogMessage is called and the
// full message gets streamed to the appropriate destination.
//
// You shouldn't actually use LogMessage's constructor to log things,
// though.  You should use the LOG() macro (and variants thereof)
// above.
class LogMessage {
 public:
  // Used for LOG(severity).
  LogMessage(const char* file, int line, LogSeverity severity);

  // Used for CHECK_EQ(), etc. Takes ownership of the given string.
  // Implied severity = LOG_FATAL.
  LogMessage(const char* file, int line, std::string* result);

  // Used for DCHECK_EQ(), etc. Takes ownership of the given string.
  LogMessage(const char* file,
             int line,
             LogSeverity severity,
             std::string* result);

  LogMessage(const LogMessage&) = delete;
  LogMessage& operator=(const LogMessage&) = delete;

  ~LogMessage();

  std::ostream& stream() { return stream_; }

 private:
  LogSeverity severity_;
  std::ostringstream stream_;

  // The file and line information passed in to the constructor.
  const char* file_;
  const int line_;

#if defined(OS_WIN)
  // Stores the current value of GetLastError in the constructor and restores
  // it in the destructor by calling SetLastError.
  // This is useful since the LogMessage class uses a lot of Win32 calls
  // that will lose the value of GLE and the code that called the log function
  // will have lost the thread error value when the log call returns.
  class SaveLastError {
   public:
    SaveLastError();
    ~SaveLastError();

    unsigned long get_error() const { return last_error_; }

   protected:
    unsigned long last_error_;
  };

  SaveLastError last_error_;
#endif
};

// A non-macro interface to the log facility; (useful
// when the logging level is not a compile-time constant).
inline void LogAtLevel(int const log_level, std::string const& msg) {
  LogMessage(__FILE__, __LINE__, log_level).stream() << msg;
}

// This class is used to explicitly ignore values in the conditional
// logging macros.  This avoids compiler warnings like "value computed
// is not used" and "statement has no effect".
class LogMessageVoidify {
 public:
  LogMessageVoidify() {}
  // This has to be an operator with a precedence lower than << but
  // higher than ?:
  void operator&(std::ostream&) {}
};

#if defined(OS_WIN)
typedef unsigned long SystemErrorCode;
#elif defined(OS_POSIX)
typedef int SystemErrorCode;
#endif

// Alias for ::GetLastError() on Windows and errno on POSIX. Avoids having to
// pull in windows.h just for GetLastError() and DWORD.
SystemErrorCode GetLastSystemErrorCode();
std::string SystemErrorCodeToString(SystemErrorCode error_code);

#if defined(OS_WIN)
// Appends a formatted system message of the GetLastError() type.
class Win32ErrorLogMessage {
 public:
  Win32ErrorLogMessage(const char* file,
                       int line,
                       LogSeverity severity,
                       SystemErrorCode err);

  Win32ErrorLogMessage(const Win32ErrorLogMessage&) = delete;
  Win32ErrorLogMessage& operator=(const Win32ErrorLogMessage&) = delete;

  // Appends the error message before destructing the encapsulated class.
  ~Win32ErrorLogMessage();

  std::ostream& stream() { return log_message_.stream(); }

 private:
  SystemErrorCode err_;
  LogMessage log_message_;
};
#elif defined(OS_POSIX)
// Appends a formatted system message of the errno type
class ErrnoLogMessage {
 public:
  ErrnoLogMessage(const char* file,
                  int line,
                  LogSeverity severity,
                  SystemErrorCode err);

  ErrnoLogMessage(const ErrnoLogMessage&) = delete;
  ErrnoLogMessage& operator=(const ErrnoLogMessage&) = delete;

  // Appends the error message before destructing the encapsulated class.
  ~ErrnoLogMessage();

  std::ostream& stream() { return log_message_.stream(); }

 private:
  SystemErrorCode err_;
  LogMessage log_message_;
};
#endif  // OS_WIN

namespace internal {

// UTF conversion functions implemented without libcef binary dependencies. Used
// by ostream operator<< overloads below.
#if defined(OS_WIN)
std::string WideToUTF8(std::wstring_view wstr);
#endif
std::string UTF16ToUTF8(std::u16string_view str16);

}  // namespace internal
}  // namespace logging
}  // namespace cef

// These functions are provided as a convenience for logging, which is where we
// use streams (it is against Google style to use streams in other places). It
// is designed to allow you to emit non-ASCII Unicode strings to the log file,
// which is normally ASCII. It is relatively slow, so try not to use it for
// common cases. Non-ASCII characters will be converted to UTF-8 by these
// operators. Based on base/strings/utf_ostream_operators.h.
#if defined(OS_WIN)
std::ostream& operator<<(std::ostream& out, std::wstring_view wstr);
inline std::ostream& operator<<(std::ostream& out, const wchar_t* wstr) {
  return out << (wstr ? std::wstring_view(wstr) : std::wstring_view());
}
inline std::ostream& operator<<(std::ostream& out, const std::wstring& wstr) {
  return out << std::wstring_view(wstr);
}
#endif  // defined(OS_WIN)

// C++20 explicitly deleted the ostream operator<< overloads for UTF
// conversions, so we provide them here.
std::ostream& operator<<(std::ostream& out, std::u16string_view str16);
inline std::ostream& operator<<(std::ostream& out, const char16_t* str16) {
  return out << (str16 ? std::u16string_view(str16) : std::u16string_view());
}
inline std::ostream& operator<<(std::ostream& out,
                                const std::u16string& str16) {
  return out << std::u16string_view(str16);
}

// The NOTIMPLEMENTED() macro annotates codepaths which have
// not been implemented yet.
//
// The implementation of this macro is controlled by NOTIMPLEMENTED_POLICY:
//   0 -- Do nothing (stripped by compiler)
//   1 -- Warn at compile time
//   2 -- Fail at compile time
//   3 -- Fail at runtime (DCHECK)
//   4 -- [default] LOG(ERROR) at runtime
//   5 -- LOG(ERROR) at runtime, only once per call-site

#ifndef NOTIMPLEMENTED_POLICY
#if defined(OS_ANDROID) && defined(OFFICIAL_BUILD)
#define NOTIMPLEMENTED_POLICY 0
#else
// Select default policy: LOG(ERROR)
#define NOTIMPLEMENTED_POLICY 4
#endif
#endif

#if defined(COMPILER_GCC)
// On Linux, with GCC, we can use __PRETTY_FUNCTION__ to get the demangled name
// of the current function in the NOTIMPLEMENTED message.
#define NOTIMPLEMENTED_MSG "Not implemented reached in " << __PRETTY_FUNCTION__
#else
#define NOTIMPLEMENTED_MSG "NOT IMPLEMENTED"
#endif

#if NOTIMPLEMENTED_POLICY == 0
#define NOTIMPLEMENTED() EAT_STREAM_PARAMETERS
#elif NOTIMPLEMENTED_POLICY == 1
// TODO, figure out how to generate a warning
#define NOTIMPLEMENTED() COMPILE_ASSERT(false, NOT_IMPLEMENTED)
#elif NOTIMPLEMENTED_POLICY == 2
#define NOTIMPLEMENTED() COMPILE_ASSERT(false, NOT_IMPLEMENTED)
#elif NOTIMPLEMENTED_POLICY == 3
#define NOTIMPLEMENTED() NOTREACHED()
#elif NOTIMPLEMENTED_POLICY == 4
#define NOTIMPLEMENTED() LOG(ERROR) << NOTIMPLEMENTED_MSG
#elif NOTIMPLEMENTED_POLICY == 5
#define NOTIMPLEMENTED()                               \
  do {                                                 \
    static bool logged_once = false;                   \
    LOG_IF(ERROR, !logged_once) << NOTIMPLEMENTED_MSG; \
    logged_once = true;                                \
  } while (0);                                         \
  EAT_STREAM_PARAMETERS
#endif

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_LOGGING_H_

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

#ifndef CEF_INCLUDE_BASE_CEF_THREAD_CHECKER_H_
#define CEF_INCLUDE_BASE_CEF_THREAD_CHECKER_H_
#pragma once

#if defined(USING_CHROMIUM_INCLUDES)
// When building CEF include the Chromium header directly.
#include "base/threading/thread_checker.h"
#else  // !USING_CHROMIUM_INCLUDES
// The following is substantially similar to the Chromium implementation.
// If the Chromium implementation diverges the below implementation should be
// updated to match.

#include "include/base/cef_logging.h"
#include "include/base/internal/cef_thread_checker_impl.h"

///
/// Apart from debug builds, we also enable the thread checker in
/// builds with DCHECK_ALWAYS_ON so that trybots and waterfall bots
/// with this define will get the same level of thread checking as
/// debug bots.
///
#if DCHECK_IS_ON()
#define ENABLE_THREAD_CHECKER 1
#else
#define ENABLE_THREAD_CHECKER 0
#endif

namespace base {

namespace cef_internal {

///
/// Do nothing implementation, for use in release mode.
///
/// Note: You should almost always use the ThreadChecker class to get the
/// right version for your build configuration.
///
class ThreadCheckerDoNothing {
 public:
  bool CalledOnValidThread() const { return true; }

  void DetachFromThread() {}
};

}  // namespace cef_internal

///
/// ThreadChecker is a helper class used to help verify that some methods of a
/// class are called from the same thread. It provides identical functionality
/// to base::NonThreadSafe, but it is meant to be held as a member variable,
/// rather than inherited from base::NonThreadSafe.
///
/// While inheriting from base::NonThreadSafe may give a clear indication about
/// the thread-safety of a class, it may also lead to violations of the style
/// guide with regard to multiple inheritance. The choice between having a
/// ThreadChecker member and inheriting from base::NonThreadSafe should be based
/// on whether:
///  - Derived classes need to know the thread they belong to, as opposed to
///    having that functionality fully encapsulated in the base class.
///  - Derived classes should be able to reassign the base class to another
///    thread, via DetachFromThread.
///
/// If neither of these are true, then having a ThreadChecker member and calling
/// CalledOnValidThread is the preferable solution.
///
/// Example:
///
/// <pre>
///   class MyClass {
///    public:
///     void Foo() {
///       DCHECK(thread_checker_.CalledOnValidThread());
///       ... (do stuff) ...
///     }
///
///    private:
///     ThreadChecker thread_checker_;
///   }
/// </pre>
///
/// In Release mode, CalledOnValidThread will always return true.
///
#if ENABLE_THREAD_CHECKER
class ThreadChecker : public cef_internal::ThreadCheckerImpl {};
#else
class ThreadChecker : public cef_internal::ThreadCheckerDoNothing {};
#endif  // ENABLE_THREAD_CHECKER

#undef ENABLE_THREAD_CHECKER

}  // namespace base

#endif  // !USING_CHROMIUM_INCLUDES

#endif  // CEF_INCLUDE_BASE_CEF_THREAD_CHECKER_H_

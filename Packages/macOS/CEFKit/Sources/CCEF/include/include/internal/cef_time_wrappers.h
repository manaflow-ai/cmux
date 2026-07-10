// Copyright (c) 2022 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_INTERNAL_CEF_TIME_WRAPPERS_H_
#define CEF_INCLUDE_INTERNAL_CEF_TIME_WRAPPERS_H_
#pragma once

#include "include/internal/cef_time.h"

#if defined(USING_CHROMIUM_INCLUDES)
#include "base/time/time.h"
#endif

///
/// Represents a wall clock time in UTC. Values are not guaranteed to be
/// monotonically non-decreasing and are subject to large amounts of skew.
/// Time is stored internally as microseconds since the Windows epoch (1601).
///
/// This is equivalent of Chromium `base::Time` (see base/time/time.h).
///
class CefBaseTime : public cef_basetime_t {
 public:
  CefBaseTime() : cef_basetime_t{} {}
  CefBaseTime(const cef_basetime_t& value) : cef_basetime_t(value) {}

#if defined(USING_CHROMIUM_INCLUDES)
  CefBaseTime(const base::Time& value)
      : cef_basetime_t{value.ToDeltaSinceWindowsEpoch().InMicroseconds()} {}

  operator base::Time() const {
    return base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(val));
  }
#endif

  static CefBaseTime Now() { return cef_basetime_now(); }
};

///
/// Class representing a time.
///
class CefTime : public cef_time_t {
 public:
  CefTime() : cef_time_t{} {}
  CefTime(const cef_time_t& r) : cef_time_t(r) {}
  explicit CefTime(time_t r) { SetTimeT(r); }
  explicit CefTime(double r) { SetDoubleT(r); }

  ///
  /// Converts to/from time_t.
  ///
  void SetTimeT(time_t r) { cef_time_from_timet(r, this); }
  time_t GetTimeT() const {
    time_t time = 0;
    cef_time_to_timet(this, &time);
    return time;
  }

  ///
  /// Converts to/from a double which is the number of seconds since epoch
  /// (Jan 1, 1970). Webkit uses this format to represent time. A value of 0
  /// means "not initialized".
  ///
  void SetDoubleT(double r) { cef_time_from_doublet(r, this); }
  double GetDoubleT() const {
    double time = 0;
    cef_time_to_doublet(this, &time);
    return time;
  }

  ///
  /// Set this object to now.
  ///
  void Now() { cef_time_now(this); }

  ///
  /// Return the delta between this object and |other| in milliseconds.
  ///
  long long Delta(const CefTime& other) {
    long long delta = 0;
    cef_time_delta(this, &other, &delta);
    return delta;
  }
};

#endif  // CEF_INCLUDE_INTERNAL_CEF_TIME_WRAPPERS_H_

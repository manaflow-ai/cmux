// Copyright (c) 2016 Marshall A. Greenblatt. Portions copyright (c) 2011
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
//
// ---------------------------------------------------------------------------
//
// The contents of this file are only available to applications that link
// against the libcef_dll_wrapper target.
//

#ifndef CEF_INCLUDE_SCOPED_TEMP_DIR_H_
#define CEF_INCLUDE_SCOPED_TEMP_DIR_H_
#pragma once

#include "include/base/cef_build.h"
#include "include/cef_base.h"

///
/// An object representing a temporary / scratch directory that should be
/// cleaned up (recursively) when this object goes out of scope.  Note that
/// since deletion occurs during the destructor, no further error handling is
/// possible if the directory fails to be deleted.  As a result, deletion is not
/// guaranteed by this class.
///
/// Multiple calls to the methods which establish a temporary directory
/// (CreateUniqueTempDir, CreateUniqueTempDirUnderPath, and Set) must have
/// intervening calls to Delete or Take, or the calls will fail.
///
class CefScopedTempDir {
 public:
  ///
  /// No directory is owned/created initially.
  ///
  CefScopedTempDir();

  CefScopedTempDir(const CefScopedTempDir&) = delete;
  CefScopedTempDir& operator=(const CefScopedTempDir&) = delete;

  ///
  /// Recursively delete path.
  ///
  ~CefScopedTempDir();

  ///
  /// Creates a unique directory in TempPath, and takes ownership of it.
  /// See file_util::CreateNewTemporaryDirectory.
  ///
  [[nodiscard]] bool CreateUniqueTempDir();

  ///
  /// Creates a unique directory under a given path, and takes ownership of it.
  ///
  [[nodiscard]] bool CreateUniqueTempDirUnderPath(const CefString& path);

  ///
  /// Takes ownership of directory at |path|, creating it if necessary.
  /// Don't call multiple times unless Take() has been called first.
  ///
  [[nodiscard]] bool Set(const CefString& path);

  ///
  /// Deletes the temporary directory wrapped by this object.
  ///
  [[nodiscard]] bool Delete();

  ///
  /// Caller takes ownership of the temporary directory so it won't be destroyed
  /// when this object goes out of scope.
  ///
  CefString Take();

  ///
  /// Returns the path to the created directory. Call one of the
  /// CreateUniqueTempDir* methods before getting the path.
  ///
  const CefString& GetPath() const;

  ///
  /// Returns true if path_ is empty.
  ///
  bool IsEmpty() const;

  ///
  /// Returns true if path_ is non-empty and exists.
  ///
  bool IsValid() const;

 private:
  CefString path_;
};

#endif  // CEF_INCLUDE_SCOPED_TEMP_DIR_H_

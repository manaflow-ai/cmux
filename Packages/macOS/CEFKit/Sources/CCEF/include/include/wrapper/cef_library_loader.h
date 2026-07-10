// Copyright (c) 2018 Marshall A. Greenblatt. All rights reserved.
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

#ifndef CEF_INCLUDE_WRAPPER_CEF_LIBRARY_LOADER_H_
#define CEF_INCLUDE_WRAPPER_CEF_LIBRARY_LOADER_H_
#pragma once

#include "include/base/cef_build.h"

#if defined(OS_MAC)

#ifdef __cplusplus
extern "C" {
#endif

///
/// Load the CEF library at the specified |path|. Returns true (1) on
/// success and false (0) on failure.
///
int cef_load_library(const char* path);

///
/// Unload the CEF library that was previously loaded. Returns true (1)
/// on success and false (0) on failure.
///
int cef_unload_library(void);

///
/// Load the CEF library from the expected app bundle location relative to the
/// executable. Pass |helper| as 1 for helper processes or 0 for the main
/// process. Returns an opaque handle on success or NULL on failure. The
/// returned handle should be passed to cef_scoped_library_loader_free()
/// immediately before process termination. This is a wrapper around
/// CefScopedLibraryLoader for C API users.
///
void* cef_scoped_library_loader_create(int helper);

///
/// Destroy the specified library loader handle created by
/// cef_scoped_library_loader_create().
///
void cef_scoped_library_loader_free(void* loader);

#ifdef __cplusplus
}
#endif

#endif  // defined(OS_MAC)

#ifdef __cplusplus
#include <string>

#if defined(OS_MAC)

///
/// Scoped helper for loading and unloading the CEF framework library at
/// runtime from the expected location in the app bundle. Loading at runtime
/// instead of linking directly is a requirement of the macOS sandbox
/// implementation.
///
/// Example usage in the main process:
///
/// <pre>
///   #include "include/wrapper/cef_library_loader.h"
///
///   int main(int argc, char* argv[]) {
///     // Dynamically load the CEF framework library.
///     CefScopedLibraryLoader library_loader;
///     if (!library_loader.LoadInMain())
///       return 1;
///
///     // Continue with CEF initialization...
///   }
/// </pre>
///
/// Example usage in the helper process:
///
/// <pre>
///   #include "include/cef_sandbox_mac.h"
///   #include "include/wrapper/cef_library_loader.h"
///
///   int main(int argc, char* argv[]) {
///     // Dynamically load and initialize the macOS sandbox for this helper
///     // process.
///     CefScopedSandboxContext sandbox_context;
///     if (!sandbox_context.Initialize(argc, argv))
///       return 1;
///
///     // Dynamically load the CEF framework library.
///     CefScopedLibraryLoader library_loader;
///     if (!library_loader.LoadInHelper())
///       return 1;
///
///     // Continue with CEF initialization...
///   }
/// </pre>
///
class CefScopedLibraryLoader final {
 public:
  CefScopedLibraryLoader();

  CefScopedLibraryLoader(const CefScopedLibraryLoader&) = delete;
  CefScopedLibraryLoader& operator=(const CefScopedLibraryLoader&) = delete;

  ~CefScopedLibraryLoader();

  ///
  /// Load the CEF framework in the main process from the expected app
  /// bundle location relative to the executable. Returns true if the
  /// load succeeds.
  ///
  bool LoadInMain() { return Load(false); }

  ///
  /// Load the CEF framework in the helper process from the expected app
  /// bundle location relative to the executable. Returns true if the
  /// load succeeds.
  ///
  bool LoadInHelper() { return Load(true); }

 private:
  bool Load(bool helper);

  bool loaded_ = false;
};

#elif defined(OS_WIN)
#include <windows.h>

#include "include/cef_version_info.h"

///
/// Scoped helper for loading the CEF library at runtime from a specific
/// location on disk. Can optionally be used to verify code signing status and
/// Chromium version compatibility at the same time. Binaries using this helper
/// must be built with the "/DELAYLOAD:libcef.dll" linker flag.
///
/// Example usage:
///
/// <pre>
///   #include "include/wrapper/cef_library_loader.h"
///
///   int APIENTRY wWinMain(HINSTANCE hInstance,
///                         HINSTANCE hPrevInstance,
///                         LPTSTR lpCmdLine,
///                         int nCmdShow)
///     // Version that was used to compile the CEF client app.
///     cef_version_info_t version_info = {};
///     CEF_POPULATE_VERSION_INFO(&version_info);
///
///     // Dynamically load libcef.dll from the specified location, and verify
///     // that the Chromium version is compatible. Any failures will
///     // intentionally crash the application. All CEF distribution resources
///     // (DLLs, pak, etc) must be located in the same directory.
///     CefScopedLibraryLoader library_loader;
///     if (!library_loader.LoadInSubProcessAssert(&version_info)) {
///       // Not running as a potentially sandboxed sub-process.
///       // Choose the appropriate path for loading libcef.dll...
///       const wchar_t* path = L"c:\\path\\to\\myapp\\cef\\libcef.dll";
///       if (!library_loader.LoadInMainAssert(path, nullptr, true,
///                                            &version_info)) {
///         // The load failed. We'll crash before reaching this line.
///         NOTREACHED();
///         return CEF_RESULT_CODE_KILLED;
///       }
///     }
///
///     // Continue with CEF initialization...
///   }
/// </pre>
///
class CefScopedLibraryLoader final {
 public:
  CefScopedLibraryLoader();

  CefScopedLibraryLoader(const CefScopedLibraryLoader&) = delete;
  CefScopedLibraryLoader& operator=(const CefScopedLibraryLoader&) = delete;

  ~CefScopedLibraryLoader();

  ///
  /// Load the CEF library (libcef.dll) in the main process from the specified
  /// absolute path. If libcef.dll is code signed then all signatures must be
  /// valid. If |thumbprint| is a SHA1 hash (e.g. 40 character upper-case
  /// hex-encoded value) then the primary signature must match that thumbprint.
  /// If |allow_unsigned| is true and |thumbprint| is nullptr then libcef.dll
  /// may be unsigned, otherwise it must be validly signed. Failure of code
  /// signing requirements or DLL loading will result in a FATAL error and
  /// application termination. If |version_info| is specified then the
  /// libcef.dll version information must also match. Returns true if the load
  /// succeeds. Usage must be protected by cef::logging::ScopedEarlySupport.
  ///
  bool LoadInMainAssert(const wchar_t* dll_path,
                        const char* thumbprint,
                        bool allow_unsigned,
                        cef_version_info_t* version_info);

  ///
  /// Load the CEF library (libcef.dll) in a sub-process that may be sandboxed.
  /// The path will be determined based on command-line arguments for the
  /// current process. Failure of DLL loading will result in a FATAL error and
  /// application termination. If |version_info| is specified then the
  /// libcef.dll version information must match. Returns true if the load
  /// succeeds. Usage must be protected by cef::logging::ScopedEarlySupport.
  ///
  bool LoadInSubProcessAssert(cef_version_info_t* version_info);

 private:
  HMODULE handle_ = nullptr;
};

namespace switches {
// Changes to this value require rebuilding libcef.dll.
inline constexpr char kLibcefPath[] = "libcef-path";
inline constexpr wchar_t kLibcefPathW[] = L"libcef-path";
}  // namespace switches

#endif  // defined(OS_WIN)
#endif  // __cplusplus

#endif  // CEF_INCLUDE_WRAPPER_CEF_LIBRARY_LOADER_H_

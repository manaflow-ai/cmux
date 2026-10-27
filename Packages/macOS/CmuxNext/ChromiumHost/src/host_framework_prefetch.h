// The Chromium framework's file-cache read, in the Chromium Host (task
// p01-process-101 of plans/cmux-next/chrome-parity/p01-process.md).
//
// In host mode cmux never maps the framework: this process maps it
// (cmux_shim_load) and reads it. Right after the map, one background item
// reads the binary and the top-level files of its Resources folder (pak
// files, ICU data, V8 snapshots; locale folders are left out) front to back,
// while cmux attaches and CefInitialize runs. CefInitialize and the first
// page window then fault in pages already read instead of 16 KiB at a time
// from a cold disk, as in process (CEFFrameworkPrefetch.swift measured about
// 0.75 s of main thread per step on a cold cache against 0.15 s cached).
// Chrome prefetches its library the same way, beside the start instead of
// before it: base/android/library_loader/library_prefetcher.cc
// (NativeLibraryPrefetcher::ForkAndPrefetchNativeLibrary); the read itself
// is base/files/file_util.h PreReadFile's.
//
// POSIX only (no AppKit, no dispatch): browser_host_main.mm posts
// PreReadFramework on a user-initiated global queue, and
// tests/host_framework_prefetch_test.cpp runs it on Linux and macOS.
#pragma once

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace cmux_host {

// What one read did.
struct FrameworkPrefetchReport {
  int64_t bytes = 0;
  // Files read to their end; a file that would not open is not counted.
  int files = 0;
};

// The framework binary, then the top-level regular files of Resources in name
// order (CEFFrameworkPrefetch.files(in:)).
inline std::vector<std::string> FrameworkPrefetchFiles(const std::string& framework) {
  std::vector<std::string> files = {framework + "/Chromium Embedded Framework"};
  const std::string resources = framework + "/Resources";
  DIR* dir = opendir(resources.c_str());
  if (!dir) return files;
  std::vector<std::string> names;
  while (const dirent* entry = readdir(dir)) {
    const std::string name = entry->d_name;
    struct stat info;
    if (name == "." || name == ".." || stat((resources + "/" + name).c_str(), &info) != 0 ||
        !S_ISREG(info.st_mode)) {
      continue;
    }
    names.push_back(name);
  }
  closedir(dir);
  std::sort(names.begin(), names.end());
  for (const std::string& name : names) files.push_back(resources + "/" + name);
  return files;
}

// Reads each file of `paths` front to back in 1 MiB preads into the file
// cache. A file that would not open is skipped; one whose read fails counts
// its bytes but not the file.
inline FrameworkPrefetchReport PreReadFiles(const std::vector<std::string>& paths) {
  constexpr size_t kChunk = 1 << 20;
  FrameworkPrefetchReport report;
  const std::unique_ptr<char[]> buffer(new char[kChunk]);
  for (const std::string& path : paths) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) continue;
    off_t offset = 0;
    ssize_t count;
    while ((count = pread(fd, buffer.get(), kChunk, offset)) > 0 || (count < 0 && errno == EINTR)) {
      offset += std::max<ssize_t>(count, 0);
      report.bytes += std::max<ssize_t>(count, 0);
    }
    close(fd);
    if (count == 0) ++report.files;
  }
  return report;
}

// PreReadFiles of FrameworkPrefetchFiles(framework).
inline FrameworkPrefetchReport PreReadFramework(const std::string& framework) {
  return PreReadFiles(FrameworkPrefetchFiles(framework));
}

}  // namespace cmux_host

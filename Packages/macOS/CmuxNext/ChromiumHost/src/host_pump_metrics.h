// The Chromium Host's metrics file (plans/cmux-next/chrome-parity/p09-observability.md,
// task 104 (e)): `cef.pump`, the time of each pass of the host's message loop
// in microseconds, in the layout of the app's metrics files
// (Sources/CmuxNextMetrics/MetricsStore+Layout.swift, MetricsImage.swift), so
// the app folds it as a child's file (ChildMetricsReader, role chromium_host),
// and task 060 reads the host's pump numbers from it. Chrome's child processes
// keep their histograms in shared memory the browser merges from the same way
// (base/metrics/persistent_histogram_allocator.h,
// components/metrics/content/subprocess_metrics_provider.cc).
//
// One histogram, so the file is one 4 KiB page:
//   0     "CMXMETRC", u32 version 1, u32 directory offset 1024, u32 entry count,
//         u16 role, u16 log-linear sub-buckets log2, u32 pid, u32 entry bytes 88,
//         u64 start uptime ns, u64 start unix ns, u64 byte count, u64 blocks offset;
//         the profile from 64 to 424 (MetricsProfile.Offsets): the app's, copied
//         from the app's own metrics file in the same folder (the host is part of
//         that build, on that channel), else only the boot session and build UUID
//   1024  one directory entry: name (64 bytes), u32 kind, u32 bucket count,
//         i64 maximum, u64 block offset
//   1152  the block: count, sum, buckets; then the same words logged (the app's)
// A sample is three relaxed adds. Header-only, no CEF.
#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <string>

#include "host_black_box.h"

namespace cmux_host {

// HistogramID.Layout.logLinearIndex (Histogram.swift; the Rust golden is
// cmux-tui/crates/cmux-trace/tests/fixtures/metrics-log-linear-golden.txt).
constexpr int LogLinearIndex(uint64_t value) {
  if (value < 4) return static_cast<int>(value);
  const int octave = 63 - __builtin_clzll(value);
  return octave * 4 + static_cast<int>((value >> (octave - 2)) & 3);
}

class PumpMetrics {
 public:
  // HistogramID.cefPump: microseconds, log-linear to 60 s.
  static constexpr int64_t kMaximum = 60'000'000;
  static constexpr uint32_t kSubBucketsLog2 = 2;
  static constexpr int kBucketCount = LogLinearIndex(kMaximum) + 2;

  static constexpr size_t kDirectoryOffset = 1024;
  static constexpr size_t kEntryBytes = 88;
  static constexpr size_t kBlocksOffset = (kDirectoryOffset + kEntryBytes + 63) / 64 * 64;
  static constexpr size_t kBlockBytes = 2 * (2 + kBucketCount) * 8;
  static constexpr size_t kFileBytes = (kBlocksOffset + (kBlockBytes + 63) / 64 * 64 + 4095) / 4096 * 4096;

  // The bucket of `micros`: its log-linear bucket, or the overflow bucket past kMaximum.
  static int BucketOf(uint64_t micros) {
    return micros > static_cast<uint64_t>(kMaximum) ? kBucketCount - 1 : LogLinearIndex(micros);
  }

  // The file's header and directory, written into the zeroed `image`.
  static void WriteHeader(uint8_t* image, const HostIdentity& identity, uint64_t start_uptime_ns,
                          uint64_t start_unix_ns) {
    std::memcpy(image, "CMXMETRC", 8);
    Put32(image, 8, 1);
    Put32(image, 12, kDirectoryOffset);
    Put32(image, 16, 1);
    Put16(image, 20, CMUX_TRACE_ROLE_CHROMIUM_HOST);
    Put16(image, 22, kSubBucketsLog2);
    Put32(image, 24, identity.pid);
    Put32(image, 28, kEntryBytes);
    Put64(image, 32, start_uptime_ns);
    Put64(image, 40, start_unix_ns);
    Put64(image, 48, kFileBytes);
    Put64(image, 56, kBlocksOffset);
    std::memcpy(image + 64, identity.boot_session_uuid, 16);
    std::memcpy(image + 80, identity.build_uuid, 16);
    uint8_t* entry = image + kDirectoryOffset;
    std::memcpy(entry, "cef.pump", 8);
    Put32(entry, 64, 1);  // log-linear
    Put32(entry, 68, kBucketCount);
    Put64(entry, 72, kMaximum);
    Put64(entry, 80, kBlocksOffset);
  }

  PumpMetrics(const HostIdentity& identity, uint64_t start_uptime_ns, uint64_t start_unix_ns)
      : identity_(identity), start_uptime_ns_(start_uptime_ns), start_unix_ns_(start_unix_ns) {}
  PumpMetrics(const PumpMetrics&) = delete;
  PumpMetrics& operator=(const PumpMetrics&) = delete;

  // The profile's bytes in a metrics file's header.
  static constexpr size_t kProfileOffset = 64;
  static constexpr size_t kProfileEnd = 424;

  // Copies the profile of the metrics file at `path` (the app's) into `image`;
  // false, and `image` untouched, when it is not a version 1 metrics file.
  static bool CopyProfile(const std::string& path, uint8_t* image) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    uint8_t header[kProfileEnd];
    const ssize_t read = pread(fd, header, sizeof header, 0);
    close(fd);
    if (read != static_cast<ssize_t>(sizeof header) || std::memcmp(header, "CMXMETRC", 8) != 0 || header[8] != 1) {
      return false;
    }
    std::memcpy(image + kProfileOffset, header + kProfileOffset, kProfileEnd - kProfileOffset);
    return true;
  }

  // Makes the file in `directory`, with the profile of app `app_pid`'s file
  // there, and records into it from then on (a pass before that is not
  // counted). Once, on the host's files thread.
  bool Adopt(const std::string& directory, uint32_t app_pid) {
    if (block_.load(std::memory_order_acquire)) return false;
    void* file = MapNewFile(HostMetricsPath(directory, identity_.pid), kFileBytes);
    if (!file) return false;
    auto* image = static_cast<uint8_t*>(file);
    WriteHeader(image, identity_, start_uptime_ns_, start_unix_ns_);
    CopyProfile(directory + "/metrics-app-" + std::to_string(app_pid) + ".bin", image);
    block_.store(reinterpret_cast<uint64_t*>(image + kBlocksOffset), std::memory_order_release);
    return true;
  }

  // One pass of `micros` (main thread, or any thread: the adds are atomic).
  void Record(uint64_t micros) {
    Record(block_.load(std::memory_order_acquire), micros);
  }

  // A block at `block` (count, sum, buckets): the three adds of one sample.
  static void Record(uint64_t* block, uint64_t micros) {
    if (!block) return;
    std::atomic_ref<uint64_t>(block[2 + BucketOf(micros)]).fetch_add(1, std::memory_order_relaxed);
    std::atomic_ref<uint64_t>(block[0]).fetch_add(1, std::memory_order_relaxed);
    std::atomic_ref<uint64_t>(block[1]).fetch_add(micros, std::memory_order_relaxed);
  }

 private:
  static void Put16(uint8_t* at, size_t offset, uint64_t value) { Put(at, offset, value, 2); }
  static void Put32(uint8_t* at, size_t offset, uint64_t value) { Put(at, offset, value, 4); }
  static void Put64(uint8_t* at, size_t offset, uint64_t value) { Put(at, offset, value, 8); }
  static void Put(uint8_t* at, size_t offset, uint64_t value, size_t size) {
    for (size_t index = 0; index < size; ++index) at[offset + index] = static_cast<uint8_t>(value >> (8 * index));
  }

  const HostIdentity identity_;
  const uint64_t start_uptime_ns_;
  const uint64_t start_unix_ns_;
  std::atomic<uint64_t*> block_{nullptr};
};

static_assert(PumpMetrics::kBucketCount == 105, "cef.pump's buckets (HistogramID.Layout.logLinear(maximum: 60_000_000))");
static_assert(PumpMetrics::kFileBytes == 4096, "one page");

}  // namespace cmux_host

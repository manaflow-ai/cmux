// The Chromium Host's black box and crash keys (plans/cmux-next/chrome-parity/
// p09-observability.md, task 104 (a)), written with the C ring writer
// (CEFShim/src/cmux_trace.h, task 094) under role chromium_host.
//
// Like the app's TraceBlackBox: the ring and the crash-key page live on the heap
// from the host's first line, and Adopt, once and off the main thread, moves
// them into the trace folder's files, where cmux reads them after the host
// ended (ChromiumHostExitReporter: the black-box tail of its Sentry event) and
// the trace recording reads them while it runs. Chrome's TraceLog and its
// crash keys work the same way: a trace point is a few stores into memory set
// aside up front, never an allocation or a lock
// (base/trace_event/trace_log.cc, components/crash/core/common/crash_key.h).
//
// The ring's catalog names have SignpostName's raw values as their ids, so a
// host record decodes to the name the app's records of the same point carry.
//
// Header-only, no CEF; tests/host_black_box_test.cpp builds it on Linux.
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#endif

#include "cmux_trace.h"
#include "host_tracing.h"

namespace cmux_host {

// SignpostName's raw values (Sources/CmuxNextSignposts/SignpostName.swift).
inline constexpr uint16_t kTraceCefPump = 14;
inline constexpr uint16_t kTraceCefCreateBrowser = 15;
inline constexpr uint16_t kTraceCefHostInput = 35;
inline constexpr uint16_t kTraceHangThreadHung = 52;
// Their category bits (SignpostName+TraceCategory.swift: cef, hang).
inline constexpr uint8_t kTraceCategoryCef = 4;
inline constexpr uint8_t kTraceCategoryHang = 7;
static_assert(CMUX_TRACE_CAT_CEF == uint64_t{1} << kTraceCategoryCef && CMUX_TRACE_CAT_HANG == uint64_t{1} << kTraceCategoryHang,
              "the catalog's category bits");
static_assert(kTraceRecordingCategories == CMUX_TRACE_CAT_RECORDING, "host_tracing.h's recording categories");

inline constexpr cmux_trace_catalog_name kHostTraceCatalog[] = {
    {kTraceCefPump, CMUX_TRACE_NAME_CATALOG, kTraceCategoryCef, "cef.pump"},
    {kTraceCefCreateBrowser, CMUX_TRACE_NAME_CATALOG, kTraceCategoryCef, "cef.create_browser"},
    {kTraceCefHostInput, CMUX_TRACE_NAME_CATALOG, kTraceCategoryCef, "cef.host_input"},
    {kTraceHangThreadHung, CMUX_TRACE_NAME_CATALOG, kTraceCategoryHang, "hang.thread_hung"},
};

// What the ring and page headers say of this process.
struct HostIdentity {
  uint32_t pid = 0;
  uint64_t process_start_unix_us = 0;
  uint8_t boot_session_uuid[16] = {};
  uint8_t build_uuid[16] = {};

#if defined(__APPLE__)
  // This process: its pid, its start (KERN_PROC), the boot session
  // (kern.bootsessionuuid) and the main executable's LC_UUID, as
  // TraceBlackBox.ProcessFacts reads them in the app.
  static HostIdentity Current() {
    HostIdentity identity;
    identity.pid = static_cast<uint32_t>(getpid());
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof info;
    if (sysctl(mib, 4, &info, &size, nullptr, 0) == 0 && size == sizeof info) {
      identity.process_start_unix_us = static_cast<uint64_t>(info.kp_proc.p_starttime.tv_sec) * 1000000 +
                                       static_cast<uint64_t>(info.kp_proc.p_starttime.tv_usec);
    }
    char text[64] = {0};
    size = sizeof text - 1;
    if (sysctlbyname("kern.bootsessionuuid", text, &size, nullptr, 0) == 0) ParseUuid(text, identity.boot_session_uuid);
    if (const mach_header* header = _dyld_get_image_header(0)) MainImageUuid(header, identity.build_uuid);
    return identity;
  }
#endif

  // "XXXXXXXX-XXXX-..." into 16 bytes; leaves `out` zero for anything else.
  static void ParseUuid(const char* text, uint8_t out[16]) {
    uint8_t bytes[16] = {};
    int nibbles = 0;
    for (const char* at = text; *at && nibbles < 32; ++at) {
      const char c = *at;
      if (c == '-') continue;
      int value = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
      if (value < 0) return;
      bytes[nibbles / 2] = static_cast<uint8_t>(bytes[nibbles / 2] | value << (nibbles % 2 ? 0 : 4));
      ++nibbles;
    }
    if (nibbles == 32) std::memcpy(out, bytes, 16);
  }

#if defined(__APPLE__)
  static void MainImageUuid(const mach_header* header, uint8_t out[16]) {
    if (header->magic != MH_MAGIC_64) return;
    const auto* command = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(header) +
                                                                sizeof(mach_header_64));
    for (uint32_t index = 0; index < header->ncmds; ++index) {
      if (command->cmd == LC_UUID) {
        std::memcpy(out, reinterpret_cast<const uuid_command*>(command)->uuid, 16);
        return;
      }
      command = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(command) + command->cmdsize);
    }
  }
#endif
};

// The file names CmuxNextTrace and CmuxNextMetrics give role chromium_host
// (TraceRingFile.fileName, CrashKeyPage.fileName, MetricsStore.fileName).
inline std::string HostTracePath(const std::string& directory, uint32_t pid, const char* suffix) {
  return directory + "/chromium-host-" + std::to_string(pid) + suffix;
}
inline std::string HostMetricsPath(const std::string& directory, uint32_t pid) {
  return directory + "/metrics-chromium-host-" + std::to_string(pid) + ".bin";
}

// A new file of `bytes` zero bytes at `path`, mapped shared and never
// unmapped (a writer on any thread may still reach it); nullptr when it could
// not be made. Blocking file work: the host's files thread only.
inline void* MapNewFile(const std::string& path, size_t bytes) {
  const int fd = open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return nullptr;
  void* mapping = nullptr;
  if (ftruncate(fd, static_cast<off_t>(bytes)) == 0) {
    mapping = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) mapping = nullptr;
  }
  close(fd);
  if (!mapping) unlink(path.c_str());
  return mapping;
}

// The calling thread's writer of `tracer` (thread-local, made at its first
// record; its exit completes its chunk and frees its thread entries).
inline cmux_trace_writer* ThreadWriterOf(cmux_trace_tracer* tracer) {
  struct Slot {
    cmux_trace_tracer* tracer = nullptr;
    cmux_trace_writer writer;
    ~Slot() {
      if (tracer) cmux_trace_writer_exit(tracer, &writer);
    }
  };
  thread_local Slot slot;
  if (slot.tracer != tracer) {
    if (slot.tracer) cmux_trace_writer_exit(slot.tracer, &slot.writer);
    cmux_trace_writer_init(&slot.writer, nullptr);
    slot.tracer = tracer;
  }
  return &slot.writer;
}

// The host's one tracer and crash-key page: browser_host_main.mm makes it
// first in main and keeps it for the process's life. Its memory is never
// freed: a thread may write until the process ends (TraceLog is leaked for
// the same reason). Any thread.
class HostBlackBox final : public TraceRecorder {
 public:
  HostBlackBox(const HostIdentity& identity, uint64_t uptime_ns, uint64_t unix_ns, uint64_t continuous_ns)
      : identity_(identity), start_uptime_ns_(uptime_ns) {
    const cmux_trace_layout layout =
        cmux_trace_layout_of(cmux_trace_role_sizes(CMUX_TRACE_ROLE_CHROMIUM_HOST, CMUX_TRACE_RING_BLACK_BOX));
    void* heap = std::calloc(1, layout.total_bytes);
    void* page = std::calloc(1, CMUX_CRASH_KEYS_PAGE_BYTES);
    if (!heap || !page) {
      std::free(heap);
      std::free(page);
      return;  // no black box: every trace point and key is a no-op
    }
    const cmux_trace_ring ring = cmux_trace_ring_on(heap, layout);
    cmux_trace_header_fields fields = Fields(CMUX_TRACE_RING_BLACK_BOX, uptime_ns, unix_ns, continuous_ns);
    cmux_trace_ring_init(&ring, &fields, kHostTraceCatalog, sizeof kHostTraceCatalog / sizeof kHostTraceCatalog[0]);
    cmux_trace_tracer_init(tracer_, &ring, CMUX_TRACE_CAT_BLACKBOX);
    keys_.store(cmux_crash_keys_init(page, CMUX_TRACE_ROLE_CHROMIUM_HOST, identity.pid, identity.process_start_unix_us,
                                     identity.build_uuid, uptime_ns)
                    .base,
                std::memory_order_release);
    ready_ = true;
  }
  HostBlackBox(const HostBlackBox&) = delete;
  HostBlackBox& operator=(const HostBlackBox&) = delete;

  // Moves the black box and the crash-key page into `directory`'s files and
  // makes the recording ring there (sparse: its pages take disk only once a
  // recording writes them). Once, on the host's files thread. False when a
  // file could not be made; what was made stays.
  bool Adopt(const std::string& directory) {
    if (!ready_ || adopted_.exchange(true)) return false;
    mkdir(directory.c_str(), 0700);
    const cmux_trace_layout layout = tracer_->rings[CMUX_TRACE_SLOT_HEAP].layout;
    bool ok = true;
    if (void* file = MapNewFile(HostTracePath(directory, identity_.pid, ".blackbox.cmxtrace"), layout.total_bytes)) {
      const cmux_trace_ring ring = cmux_trace_ring_on(file, layout);
      ok = cmux_trace_tracer_adopt(tracer_, &ring, identity_.process_start_unix_us, identity_.boot_session_uuid) ==
           CMUX_TRACE_OK;
    } else {
      ok = false;
    }
    if (void* file = MapNewFile(HostTracePath(directory, identity_.pid, ".crashkeys"), CMUX_CRASH_KEYS_PAGE_BYTES)) {
      // A key set while this copies keeps the heap's value until it is set again.
      std::memcpy(file, keys_.load(std::memory_order_acquire), CMUX_CRASH_KEYS_PAGE_BYTES);
      keys_.store(static_cast<uint8_t*>(file), std::memory_order_release);
    } else {
      ok = false;
    }
    const cmux_trace_layout recording =
        cmux_trace_layout_of(cmux_trace_role_sizes(CMUX_TRACE_ROLE_CHROMIUM_HOST, CMUX_TRACE_RING_RECORDING));
    if (void* file = MapNewFile(HostTracePath(directory, identity_.pid, ".recording.cmxtrace"), recording.total_bytes)) {
      const cmux_trace_ring ring = cmux_trace_ring_on(file, recording);
      cmux_trace_header_fields fields = Fields(CMUX_TRACE_RING_RECORDING, start_uptime_ns_, 0, 0);
      cmux_trace_ring_init(&ring, &fields, kHostTraceCatalog, sizeof kHostTraceCatalog / sizeof kHostTraceCatalog[0]);
      ok = cmux_trace_tracer_attach_recording(tracer_, &ring) == CMUX_TRACE_OK && ok;
    } else {
      ok = false;
    }
    return ok;
  }

  // TRACE_START's ring (host_tracing.h).
  bool StartRecording(uint64_t categories) override {
    if (!ready_) return false;
    return cmux_trace_tracer_start_recording(tracer_, categories & CMUX_TRACE_CAT_ALL, cmux_trace_now_ns(),
                                             cmux_trace_unix_ns(), cmux_trace_continuous_ns()) == CMUX_TRACE_OK;
  }
  bool StopRecording() override { return ready_ && cmux_trace_tracer_stop(tracer_) == CMUX_TRACE_OK; }

  // Whether `category` records now: one relaxed load.
  bool Enabled(uint64_t category) { return ready_ && cmux_trace_enabled(tracer_, category); }

  // One record of catalog name `name` now, when `category` records.
  void Point(uint64_t category, uint16_t name, uint8_t phase, uint64_t arg0 = 0, uint64_t arg1 = 0,
             uint8_t flags = 0) {
    if (!Enabled(category)) return;
    cmux_trace_point(tracer_, ThreadWriterOf(tracer_), category, name, phase, flags, arg0, arg1);
  }

  // A crash key (cmux_trace.h CMUX_CRASH_KEY_*): one relaxed store.
  void SetKey(uint32_t slot, uint64_t value) {
    uint8_t* base = keys_.load(std::memory_order_acquire);
    if (base) cmux_crash_keys_set(cmux_crash_keys{base}, slot, value);
  }
  uint64_t Key(uint32_t slot) const {
    uint8_t* base = keys_.load(std::memory_order_acquire);
    return base ? cmux_crash_keys_get(cmux_crash_keys{base}, slot) : 0;
  }

  // The ring writers write into now (tests and snapshots).
  const cmux_trace_ring* active_ring() { return ready_ ? cmux_trace_tracer_active_ring(tracer_) : nullptr; }
  uint32_t pid() const { return identity_.pid; }

 private:
  cmux_trace_header_fields Fields(uint8_t kind, uint64_t uptime_ns, uint64_t unix_ns, uint64_t continuous_ns) const {
    cmux_trace_header_fields fields;
    std::memset(&fields, 0, sizeof fields);
    fields.pid = identity_.pid;
    fields.role = CMUX_TRACE_ROLE_CHROMIUM_HOST;
    fields.ring_kind = kind;
    fields.clock_domain = CMUX_TRACE_CLOCK_DOMAIN_CURRENT;
    fields.start_uptime_ns = uptime_ns;
    fields.start_unix_ns = unix_ns;
    fields.start_continuous_ns = continuous_ns;
    fields.process_start_unix_us = identity_.process_start_unix_us;
    std::memcpy(fields.boot_session_uuid, identity_.boot_session_uuid, 16);
    std::memcpy(fields.build_uuid, identity_.build_uuid, 16);
    fields.categories = CMUX_TRACE_CAT_BLACKBOX;
    return fields;
  }

  const HostIdentity identity_;
  const uint64_t start_uptime_ns_;
  bool ready_ = false;
  std::atomic<bool> adopted_{false};
  // Never freed, as the rings: a thread's writer (ThreadWriterOf) may name it after this goes.
  cmux_trace_tracer* const tracer_ = new cmux_trace_tracer();
  std::atomic<uint8_t*> keys_{nullptr};
};

}  // namespace cmux_host

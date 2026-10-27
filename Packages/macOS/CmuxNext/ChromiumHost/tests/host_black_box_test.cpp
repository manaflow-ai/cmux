// Checks the Chromium Host's black box, crash keys, metrics file and pump
// watch (src/host_black_box.h, host_pump_metrics.h, host_pump_watch.h; task
// p09-observability-104) with no CEF:
//   - the black box records on the heap from its first line; Adopt moves it
//     into chromium-host-<pid>.blackbox.cmxtrace with every record before it
//     and makes the crash-key page, and later records land in the file; the
//     first recording makes the recording ring (none before it, none without
//     an adopted folder), moves the writers to it and back; the catalog names
//     its records with SignpostName's ids;
//   - the metrics file is metrics-chromium-host-<pid>.bin with MetricsStore's
//     header, one cef.pump entry and the app's profile; a pass adds to its
//     log-linear bucket, which matches the golden of the Swift and Rust
//     writers (argv[1]);
//   - a pump item open past its deadline is reported once (a
//     hang.thread_hung record and the hang crash key, cleared when it
//     closes, also when it closes while the watcher reports it); a short item
//     reports nothing; with nothing open the watcher parks and wakes for
//     nothing;
//   - in_cef_pump is set only inside an item; each item is one cef.pump
//     sample, and a B/E pair while the cef and task categories record.
// Run by scripts/cmux-next/tests/chromium-host-black-box.test.sh.
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "host_black_box.h"
#include "host_pump_metrics.h"
#include "host_pump_watch.h"

namespace {

using namespace cmux_host;

int failures = 0;
void Check(bool ok, const std::string& what) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
  }
}

uint64_t U64(const uint8_t* at) {
  uint64_t value = 0;
  for (int i = 0; i < 8; ++i) value |= static_cast<uint64_t>(at[i]) << (8 * i);
  return value;
}
uint32_t U32(const uint8_t* at) { return static_cast<uint32_t>(U64(at) & 0xffffffffu); }
uint16_t U16(const uint8_t* at) { return static_cast<uint16_t>(at[0] | at[1] << 8); }

struct Record {
  uint16_t name;
  uint8_t phase, flags;
  uint64_t arg0, arg1;
};

// Every published record of the ring at `base` (no writer runs, no lap wrapped).
std::vector<Record> Records(const uint8_t* base) {
  std::vector<Record> out;
  const uint64_t chunks = U32(base + CMUX_TRACE_OFF_CHUNK_COUNT);
  const uint64_t offset = U64(base + CMUX_TRACE_OFF_CHUNKS_OFFSET);
  for (uint64_t chunk = 0; chunk < chunks; ++chunk) {
    const uint8_t* at = base + offset + chunk * CMUX_TRACE_CHUNK_BYTES;
    if (U64(at + CMUX_TRACE_OFF_C_LAP_SEQ) == 0) continue;
    for (uint32_t slot = 1; slot <= CMUX_TRACE_RECORDS_PER_CHUNK; ++slot) {
      const uint8_t* record = at + slot * CMUX_TRACE_RECORD_BYTES;
      if (U32(record + CMUX_TRACE_OFF_R_SEQ) == 0) continue;
      out.push_back(Record{U16(record + 12), record[14], record[15], U64(record + CMUX_TRACE_OFF_R_ARG0),
                           U64(record + CMUX_TRACE_OFF_R_ARG1)});
    }
  }
  return out;
}

size_t Count(const std::vector<Record>& records, uint16_t name, uint8_t phase) {
  size_t count = 0;
  for (const Record& record : records) count += record.name == name && record.phase == phase;
  return count;
}

std::vector<uint8_t> ReadFile(const std::string& path) {
  std::ifstream file(path, std::ios::binary);
  return std::vector<uint8_t>((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

std::string TempDir() {
  char pattern[] = "/tmp/host-black-box.XXXXXX";
  const char* made = mkdtemp(pattern);
  return made ? made : "";
}

HostIdentity TestIdentity() {
  HostIdentity identity;
  identity.pid = 4242;
  identity.process_start_unix_us = 1'700'000'000'000'000;
  HostIdentity::ParseUuid("00112233-4455-6677-8899-AABBCCDDEEFF", identity.boot_session_uuid);
  identity.build_uuid[0] = 0x5a;
  return identity;
}

void ParsesUuids() {
  uint8_t out[16] = {};
  HostIdentity::ParseUuid("00112233-4455-6677-8899-aabbccddeeff", out);
  Check(out[0] == 0x00 && out[1] == 0x11 && out[15] == 0xff, "a boot session UUID parses");
  uint8_t untouched[16] = {};
  HostIdentity::ParseUuid("not-a-uuid", untouched);
  Check(untouched[0] == 0 && untouched[15] == 0, "anything else leaves zeros");
}

void BlackBoxMovesIntoItsFiles() {
  const std::string dir = TempDir();
  const HostIdentity identity = TestIdentity();
  HostBlackBox box(identity, cmux_trace_now_ns(), cmux_trace_unix_ns(), cmux_trace_continuous_ns());
  box.Point(CMUX_TRACE_CAT_CEF, kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_BEGIN, 0, 7, CMUX_TRACE_FLAG_ID);
  box.SetKey(CMUX_CRASH_KEY_CEF_API_VERSION, 31);
  Check(Count(Records(box.active_ring()->base), kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_BEGIN) == 1,
        "a record before adoption is in the heap ring");
  Check(box.Adopt(dir), "the files are made");
  Check(!box.Adopt(dir), "adoption is once");
  box.Point(CMUX_TRACE_CAT_CEF, kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_END, 0, 7, CMUX_TRACE_FLAG_ID);
  box.SetKey(CMUX_CRASH_KEY_CHROMIUM_BROWSER_COUNT, 2);
  // A record of a category the black box leaves out records nothing.
  box.Point(CMUX_TRACE_CAT_INPUT, kTraceCefHostInput, CMUX_TRACE_PHASE_FLOW_IN, 4, 99);

  const std::vector<uint8_t> ring = ReadFile(dir + "/chromium-host-4242.blackbox.cmxtrace");
  Check(ring.size() > CMUX_TRACE_HEADER_BYTES && std::memcmp(ring.data(), CMUX_TRACE_MAGIC, 8) == 0,
        "chromium-host-<pid>.blackbox.cmxtrace is a ring");
  if (ring.size() > CMUX_TRACE_HEADER_BYTES) {
    Check(U16(ring.data() + CMUX_TRACE_OFF_ROLE_KIND_CLOCK) == CMUX_TRACE_ROLE_CHROMIUM_HOST &&
              ring[CMUX_TRACE_OFF_ROLE_KIND_CLOCK + 2] == CMUX_TRACE_RING_BLACK_BOX,
          "of role chromium_host, kind black box");
    Check(U32(ring.data() + CMUX_TRACE_OFF_PID) == 4242, "with the host's pid");
    const std::vector<Record> records = Records(ring.data());
    Check(Count(records, kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_BEGIN) == 1,
          "the heap's record moved into the file");
    Check(Count(records, kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_END) == 1, "a later record is in the file");
    Check(Count(records, kTraceCefHostInput, CMUX_TRACE_PHASE_FLOW_IN) == 0, "input flows wait for a recording");
    // The catalog: SignpostName's ids (the script checks them against SignpostName.swift).
    const uint8_t* entry = ring.data() + U64(ring.data() + CMUX_TRACE_OFF_NAME_TABLE_OFFSET) +
                           kTraceCefPump * CMUX_TRACE_NAME_ENTRY_BYTES;
    Check(std::memcmp(entry + CMUX_TRACE_OFF_N_TEXT + 1, "cef.pump", 8) == 0, "name 14 is cef.pump");
  }

  const std::vector<uint8_t> keys = ReadFile(dir + "/chromium-host-4242.crashkeys");
  Check(keys.size() == CMUX_CRASH_KEYS_PAGE_BYTES && std::memcmp(keys.data(), CMUX_CRASH_KEYS_MAGIC, 8) == 0,
        "chromium-host-<pid>.crashkeys is a crash-key page");
  if (keys.size() == CMUX_CRASH_KEYS_PAGE_BYTES) {
    Check(U64(keys.data() + 16) == (4242 | uint64_t{CMUX_TRACE_ROLE_CHROMIUM_HOST} << 32), "of the host");
    Check(U64(keys.data() + 8 * CMUX_CRASH_KEY_CEF_API_VERSION) == 31, "a key set on the heap moved");
    Check(U64(keys.data() + 8 * CMUX_CRASH_KEY_CHROMIUM_BROWSER_COUNT) == 2, "a later key is in the file");
  }

  // A recording: the first one makes the recording ring; the writers move to it, with the recording's
  // categories, and back.
  struct stat info;
  Check(stat((dir + "/chromium-host-4242.recording.cmxtrace").c_str(), &info) != 0,
        "no recording ring before the first recording");
  Check(box.StartRecording(CMUX_TRACE_CAT_INPUT | CMUX_TRACE_CAT_TASK), "a recording starts");
  Check(!box.StartRecording(CMUX_TRACE_CAT_INPUT), "one at a time");
  box.Point(CMUX_TRACE_CAT_INPUT, kTraceCefHostInput, CMUX_TRACE_PHASE_FLOW_IN, 4, 99);
  Check(box.StopRecording() && !box.StopRecording(), "and stops once");
  box.Point(CMUX_TRACE_CAT_INPUT, kTraceCefHostInput, CMUX_TRACE_PHASE_FLOW_IN, 4, 100);
  const std::vector<uint8_t> recording = ReadFile(dir + "/chromium-host-4242.recording.cmxtrace");
  Check(recording.size() > CMUX_TRACE_HEADER_BYTES &&
            recording[CMUX_TRACE_OFF_ROLE_KIND_CLOCK + 2] == CMUX_TRACE_RING_RECORDING,
        "chromium-host-<pid>.recording.cmxtrace is the recording ring");
  if (recording.size() > CMUX_TRACE_HEADER_BYTES) {
    const std::vector<Record> records = Records(recording.data());
    Check(Count(records, kTraceCefHostInput, CMUX_TRACE_PHASE_FLOW_IN) == 1, "the recording holds its flow");
    for (const Record& record : records) {
      if (record.name == kTraceCefHostInput) Check(record.arg1 == 99, "with its flow id");
    }
  }
  Check(Count(Records(ReadFile(dir + "/chromium-host-4242.blackbox.cmxtrace").data()), kTraceCefHostInput,
              CMUX_TRACE_PHASE_FLOW_IN) == 0,
        "after the stop the black box takes input flows no more");
  Check(box.StartRecording(CMUX_TRACE_CAT_INPUT) && box.StopRecording(), "a later recording reuses the ring");
}

// A host with no trace folder keeps its black box on the heap and makes no recording ring.
void NoFolderNoRecording() {
  HostBlackBox box(TestIdentity(), cmux_trace_now_ns(), cmux_trace_unix_ns(), cmux_trace_continuous_ns());
  Check(!box.StartRecording(CMUX_TRACE_CAT_INPUT), "no adopted folder: no recording");
  box.Point(CMUX_TRACE_CAT_CEF, kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_BEGIN, 0, 1, CMUX_TRACE_FLAG_ID);
  Check(Count(Records(box.active_ring()->base), kTraceCefCreateBrowser, CMUX_TRACE_PHASE_ASYNC_BEGIN) == 1,
        "and the black box still records");
}

void MetricsFileIsTheAppsLayout(const char* golden) {
  // The log-linear buckets every writer shares.
  std::ifstream lines(golden);
  std::string line;
  int checked = 0;
  while (std::getline(lines, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream row(line);
    uint64_t value = 0;
    int bucket = 0;
    row >> value >> bucket;
    Check(LogLinearIndex(value) == bucket, "the golden bucket of " + std::to_string(value));
    ++checked;
  }
  Check(checked == 1000, "the golden has 1000 values");
  Check(PumpMetrics::BucketOf(60'000'001) == PumpMetrics::kBucketCount - 1, "past 60 s: the overflow bucket");

  const std::string dir = TempDir();
  // The app's metrics file, whose profile the host takes (MetricsProfile's offsets: app version at 104).
  std::vector<uint8_t> app(PumpMetrics::kFileBytes, 0);
  std::memcpy(app.data(), "CMXMETRC", 8);
  app[8] = 1;
  std::memcpy(app.data() + 104, "1.2.3", 5);
  std::memcpy(app.data() + 232, "nightly", 7);
  {
    std::ofstream file(dir + "/metrics-app-77.bin", std::ios::binary);
    file.write(reinterpret_cast<const char*>(app.data()), static_cast<std::streamsize>(app.size()));
  }
  const HostIdentity identity = TestIdentity();
  PumpMetrics metrics(identity, 5, 6);
  metrics.Record(10);  // before the file: not counted
  Check(metrics.Adopt(dir, 77), "the metrics file is made");
  metrics.Record(3);
  metrics.Record(1'000);
  metrics.Record(1'000);
  const std::vector<uint8_t> image = ReadFile(dir + "/metrics-chromium-host-4242.bin");
  Check(image.size() == PumpMetrics::kFileBytes, "one page");
  if (image.size() != PumpMetrics::kFileBytes) return;
  const uint8_t* base = image.data();
  Check(std::memcmp(base, "CMXMETRC", 8) == 0 && U32(base + 8) == 1 && U32(base + 12) == 1024 && U32(base + 16) == 1,
        "MetricsImage's magic, version, directory and one entry");
  Check(U16(base + 20) == CMUX_TRACE_ROLE_CHROMIUM_HOST && U16(base + 22) == 2 && U32(base + 24) == 4242 &&
            U32(base + 28) == 88,
        "role, sub-buckets, pid, entry bytes");
  Check(U64(base + 32) == 5 && U64(base + 40) == 6 && U64(base + 48) == 4096 && U64(base + 56) == 1152,
        "start times, byte count, blocks offset");
  Check(std::memcmp(base + 104, "1.2.3", 5) == 0 && std::memcmp(base + 232, "nightly", 7) == 0,
        "the app's profile");
  const uint8_t* entry = base + 1024;
  Check(std::strcmp(reinterpret_cast<const char*>(entry), "cef.pump") == 0, "the entry is cef.pump");
  Check(U32(entry + 64) == 1 && U32(entry + 68) == 105 && U64(entry + 72) == 60'000'000 && U64(entry + 80) == 1152,
        "log-linear to 60 s, 105 buckets, its block");
  const uint8_t* block = base + 1152;
  Check(U64(block) == 3 && U64(block + 8) == 2'003, "three passes and their sum");
  Check(U64(block + 8 * (2 + 3)) == 1 && U64(block + 8 * (2 + PumpMetrics::BucketOf(1'000))) == 2,
        "each pass in its bucket");
  Check(U64(block + 8 * (2 + PumpMetrics::BucketOf(10))) == 0, "a pass before the file is not counted");
}

void HangScopesReportOnce() {
  std::atomic<int> reports{0};
  std::atomic<uint64_t> overrun{0};
  constexpr uint64_t kAfter = 30'000'000;  // 30 ms
  HangScopeWatch watch(
      kAfter,
      [&](uint64_t, uint64_t over) {
        overrun = over;
        ++reports;
      },
      [] {}, &cmux_trace_now_ns);
  watch.Start("test.hang-watch");
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  Check(watch.parked() && watch.wakes() == 0, "nothing open: the watcher parks and never wakes");

  watch.Open(cmux_trace_now_ns());
  Check(!watch.Close(), "a short scope is not a hang");
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  Check(reports == 0, "and reports nothing");

  watch.Open(cmux_trace_now_ns());
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (reports == 0 && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  Check(reports == 1, "a scope open past its deadline is reported once");
  Check(watch.Close(), "its close says it was reported");
  Check(watch.hangs() == 1, "one hang");
  const uint64_t wakes = watch.wakes();
  std::this_thread::sleep_for(std::chrono::milliseconds(60));
  Check(watch.wakes() == wakes && watch.parked(), "closed: the watcher parks again");
  watch.Stop();
}

// The scope closes while the watcher reports it, before the report sets the
// key: the item's end comes first and the report's set last. The watcher
// publishes the hang only after its report, so that Close says "not reported"
// and the watcher clears the key itself. Before the fix the watcher published
// first, the end cleared the key, and the report's later set stayed: a crash
// then read as a hang in progress with no hang.
void AHangThatEndsWhileReportedLeavesNoKey() {
  std::atomic<uint64_t> key{0};
  std::atomic<bool> reporting{false};
  std::atomic<bool> closed{false};
  HangScopeWatch watch(
      30'000'000,
      [&](uint64_t began, uint64_t) {
        reporting = true;
        while (!closed) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        key = began;
      },
      [&] { key = 0; }, &cmux_trace_now_ns);
  watch.Start("test.hang-watch.race");
  watch.Open(cmux_trace_now_ns());
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!reporting && std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  Check(reporting, "the watcher reports the open scope");
  // The item ends now, as PumpWatch::End does: it clears only when Close says the hang was reported.
  if (watch.Close()) key = 0;
  closed = true;
  const auto settled = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (watch.hangs() == 0 && std::chrono::steady_clock::now() < settled) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  watch.Stop();  // joins the watcher: its report and any clear are done
  Check(watch.hangs() == 1, "one hang");
  Check(key == 0, "a hang that ended while it was reported leaves no hang key");
}

uint64_t fake_now = 0;
uint64_t FakeNow() { return fake_now; }

void PumpItemsAreSamplesAndKeys() {
  const std::string dir = TempDir();
  const HostIdentity identity = TestIdentity();
  HostBlackBox box(identity, 1, 1, 1);
  Check(box.Adopt(dir), "black box files");
  PumpMetrics metrics(identity, 1, 1);
  Check(metrics.Adopt(dir, 1), "metrics file");
  PumpWatch watch(box, metrics, &FakeNow);  // the watcher thread is not started: no hang here
  fake_now = 1'000'000;
  watch.Begin();
  Check(box.Key(CMUX_CRASH_KEY_IN_CEF_PUMP) == 1, "in_cef_pump inside an item");
  fake_now += 250'000;  // 250 us
  watch.Wait();
  Check(box.Key(CMUX_CRASH_KEY_IN_CEF_PUMP) == 0, "cleared at the wait");
  watch.Wait();  // a second wait ends nothing
  fake_now += 1'000;
  watch.Begin();
  fake_now += 2'000;
  watch.Begin();  // a new item ends the open one
  fake_now += 3'000;
  watch.Wait();
  Check(watch.items() == 3, "three items");
  Check(Count(Records(box.active_ring()->base), kTraceCefPump, CMUX_TRACE_PHASE_BEGIN) == 0,
        "no cef.pump slices in the black box");
  Check(box.StartRecording(CMUX_TRACE_CAT_TASK), "a recording with the task category");
  watch.Begin();
  fake_now += 4'000;
  box.StopRecording();  // the E still goes out: the item's B was written
  watch.Wait();
  const std::vector<Record> recorded = Records(ReadFile(dir + "/chromium-host-4242.recording.cmxtrace").data());
  Check(Count(recorded, kTraceCefPump, CMUX_TRACE_PHASE_BEGIN) == 1, "a recording item's B");
  size_t ends = 0;
  for (const std::vector<Record>& ring : {recorded, Records(box.active_ring()->base)}) {
    for (const Record& record : ring) {
      if (record.name == kTraceCefPump && record.phase == CMUX_TRACE_PHASE_END) {
        ++ends;
        Check(record.arg1 == 4, "its E has the item's time in us");
      }
    }
  }
  Check(ends == 1, "and its E");
  const std::vector<uint8_t> image = ReadFile(dir + "/metrics-chromium-host-4242.bin");
  if (image.size() == PumpMetrics::kFileBytes) {
    const uint8_t* block = image.data() + PumpMetrics::kBlocksOffset;
    Check(U64(block) == 4 && U64(block + 8) == 250 + 2 + 3 + 4, "each item is one cef.pump sample, in us");
  }
  (void)dir;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: host_black_box_test <metrics-log-linear-golden.txt>\n");
    return 2;
  }
  ParsesUuids();
  BlackBoxMovesIntoItsFiles();
  NoFolderNoRecording();
  MetricsFileIsTheAppsLayout(argv[1]);
  HangScopesReportOnce();
  AHangThatEndsWhileReportedLeavesNoKey();
  PumpItemsAreSamplesAndKeys();
  if (failures) {
    std::fprintf(stderr, "chromium-host-black-box: %d failures\n", failures);
    return 1;
  }
  std::printf("chromium-host-black-box tests: ok\n");
  return 0;
}

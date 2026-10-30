// The host's input reader as a child process, for ChromiumHostInputRingTests:
// cmux's Swift writer (ChromiumHostInputRing) on one side, the host's C++
// reader (HostInput over MachDoorbell, chromium_host_input_ring.h) on the
// other. The Swift test compiles this file and runs
//   chromium_host_input_ring_reader <doorbell name> <frames>
// with the ring's region on fd kRingFd. It checks the doorbell in, writes "r"
// on stdout, then takes frames on a stand-in UI thread and exits 0 when it got
// seqs 1...<frames> in order, each with t0 equal to its seq; 1 when a frame
// was missing or out of order, 2 for bad arguments or no ring, 3 when the
// doorbell could not be checked in, 4 when the reader ended without Stop.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <atomic>
#include <condition_variable>
#include <mutex>

#include "chromium_host_input_ring_test_support.h"

#if defined(__APPLE__)
using namespace cmux_host::input_ring;

int main(int argc, char* argv[]) {
  if (argc != 3) return 2;
  const unsigned long frames = strtoul(argv[2], nullptr, 10);
  void* mapping = MapRegion(kRingFd);
  if (frames == 0 || mapping == nullptr) return 2;
  MachDoorbell doorbell;
  if (!doorbell.CheckIn(argv[1])) return 3;
  if (write(STDOUT_FILENO, "r", 1) != 1) return 2;
  close(STDOUT_FILENO);
  testing::TaskThread ui;
  std::mutex mutex;
  std::condition_variable ready;
  bool done = false;
  bool ordered = true;
  unsigned long expected = 1;  // the UI thread's
  std::atomic<bool> ended{false};
  {
    HostInput<MachDoorbell> input(mapping, doorbell);
    input.Start([&ui](std::function<void()> task) { ui.Post(std::move(task)); },
                // Takes the whole rest of each batch (HostInput::Deliver's contract: the frames
                // from `from` on, returning how many it took).
                [&](const HostInput<MachDoorbell>::Frames& batch, size_t from) -> size_t {
                  for (size_t i = from; i < batch.size(); ++i) {
                    const cmux_host::Header& frame = batch[i];
                    ordered = ordered && frame.seq == static_cast<uint32_t>(expected) && frame.t0 == expected;
                    ++expected;
                  }
                  if (expected > frames || !ordered) {
                    std::lock_guard<std::mutex> lock(mutex);
                    done = true;
                    ready.notify_one();
                  }
                  return batch.size() - from;
                },
                [&](Reader::End) {
                  ended = true;
                  std::lock_guard<std::mutex> lock(mutex);
                  done = true;
                  ready.notify_one();
                });
    // The writer's own bound: the Swift test waits for this exit.
    const bool finished = testing::WaitFor(mutex, ready, std::chrono::seconds(60), [&] { return done; });
    ui.RunAndWait([&input] { input.Stop(); });
    ui.Stop();  // runs the tasks still posted while `input` lives
    if (!finished) return 1;
  }
  UnmapRegion(mapping);
  if (ended) return 4;
  return ordered && expected == frames + 1 ? 0 : 1;
}
#else
int main() { return 2; }  // the Mach doorbell is macOS only
#endif

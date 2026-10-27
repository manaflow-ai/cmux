// Test stand-ins for the input ring's host side (chromium_host_input_ring.h):
// a UI thread that runs posted tasks in order, and, off macOS, a pipe
// doorbell with the MachDoorbell interface. Used by
// chromium_host_input_ring_test.cpp and chromium_host_input_ring_reader.cpp.
#pragma once

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

#include "../src/chromium_host_input_ring.h"

namespace cmux_host::input_ring::testing {

// Chromium's UI thread in the tests: runs posted tasks, oldest first, on its
// own thread until Stop (the tasks posted before Stop still run).
class TaskThread {
 public:
  TaskThread() : thread_([this] { Loop(); }) {}
  TaskThread(const TaskThread&) = delete;
  TaskThread& operator=(const TaskThread&) = delete;
  ~TaskThread() { Stop(); }

  void Post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      tasks_.push_back(std::move(task));
    }
    ready_.notify_one();
  }

  // Runs on the tests' thread: posts `task` and waits until it ran.
  void RunAndWait(std::function<void()> task) {
    std::mutex done_mutex;
    std::condition_variable done_ready;
    bool done = false;
    Post([&] {
      task();
      std::lock_guard<std::mutex> lock(done_mutex);
      done = true;
      done_ready.notify_one();
    });
    std::unique_lock<std::mutex> lock(done_mutex);
    done_ready.wait(lock, [&] { return done; });
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      stopping_ = true;
    }
    ready_.notify_one();
    thread_.join();
  }

 private:
  void Loop() {
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
        if (tasks_.empty()) return;
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      task();
    }
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

// Waits on the tests' thread for `done()` (checked under `mutex`, signalled
// on `ready`), at most `limit`: false is a stall.
template <typename Done>
bool WaitFor(std::mutex& mutex, std::condition_variable& ready, std::chrono::seconds limit, Done done) {
  std::unique_lock<std::mutex> lock(mutex);
  return ready.wait_for(lock, limit, done);
}

#if !defined(__APPLE__)
// The doorbell off macOS: a byte on a pipe is a ring, and Stop writes to a
// second pipe of its own. A closed or failed bell pipe is Wake::kFailed.
class PipeDoorbell {
 public:
  // `read_fd`: the bell's read end (this side's); `write_fd`: its write end
  // for Ring, or -1 when only the other process rings.
  PipeDoorbell(int read_fd, int write_fd) : read_fd_(read_fd), write_fd_(write_fd) {
    if (pipe(stop_) != 0) stop_[0] = stop_[1] = -1;
    if (write_fd_ >= 0) fcntl(write_fd_, F_SETFL, O_NONBLOCK);
  }
  PipeDoorbell(const PipeDoorbell&) = delete;
  PipeDoorbell& operator=(const PipeDoorbell&) = delete;
  ~PipeDoorbell() {
    for (int fd : stop_) {
      if (fd >= 0) close(fd);
    }
  }

  Wake Wait() {
    pollfd fds[2] = {{stop_[0], POLLIN, 0}, {read_fd_, POLLIN, 0}};
    int count;
    do count = poll(fds, 2, -1);
    while (count < 0 && errno == EINTR);
    if (count <= 0) return Wake::kFailed;
    if (fds[0].revents != 0) return Wake::kStopped;
    char bytes[64];
    ssize_t read_count;
    do read_count = read(read_fd_, bytes, sizeof bytes);
    while (read_count < 0 && errno == EINTR);
    return read_count > 0 ? Wake::kRung : Wake::kFailed;  // 0: every writer closed the pipe
  }

  // A full pipe already holds a ring.
  bool Ring() const { return write(write_fd_, "d", 1) == 1 || errno == EAGAIN; }

  void Stop() { (void)!write(stop_[1], "s", 1); }

 private:
  int read_fd_;
  int write_fd_;
  int stop_[2] = {-1, -1};
};
#endif

}  // namespace cmux_host::input_ring::testing

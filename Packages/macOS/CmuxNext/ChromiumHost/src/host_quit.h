// The Chromium Host's quit (browser_host_main.mm's HostMain): what ends the
// host after kOpShutdown, the control channel's end, a bad message, or an
// orphan that nobody adopted or that a cmux of another version found (task
// p01-process-150). The deadline is armed first, so the process ends within
// kQuitLimitSeconds even when a close never comes; then every browser closes
// (Chromium writes its profile and each tab's history) and the message loop
// ends after the last one. The steps are the host's calls (ArmQuitDeadline,
// CFRunLoopStop, cmux_shim_close_all, cmux_shim_live_browser_count,
// CefQuitMessageLoop); host_adoption_test.cpp drives them with fakes.
//
// Header only, no CEF or AppKit. Main thread.
#pragma once

#include <functional>
#include <utility>

namespace cmux_host {

class HostQuit {
 public:
  struct Steps {
    std::function<void()> arm_deadline;       // ends the process kQuitLimitSeconds later
    std::function<void()> stop_before_start;  // no Chromium yet: leave the wait for INITIALIZE
    std::function<void()> close_all;          // every browser closes; BrowserClosed follows each
    std::function<int()> live_browsers;
    std::function<void()> quit_loop;          // ends CefRunMessageLoop
  };

  explicit HostQuit(Steps steps) : steps_(std::move(steps)) {}

  void Quit() {
    steps_.arm_deadline();
    if (!running_) {
      quit_before_start_ = true;
      steps_.stop_before_start();
      return;
    }
    if (quitting_) return;
    quitting_ = true;
    steps_.close_all();
    BrowserClosed();
  }

  // A browser closed: the loop ends after the last one of a quit.
  void BrowserClosed() {
    if (quitting_ && !loop_quit_ && steps_.live_browsers() == 0) {
      loop_quit_ = true;
      steps_.quit_loop();
    }
  }

  void set_running() { running_ = true; }
  bool quit_before_start() const { return quit_before_start_; }
  // Chromium runs and no quit began.
  bool serving() const { return running_ && !quitting_; }
  bool quitting() const { return quitting_; }
  bool loop_quit() const { return loop_quit_; }

 private:
  Steps steps_;
  bool running_ = false;  // CefInitialize returned
  bool quit_before_start_ = false;
  bool quitting_ = false;
  bool loop_quit_ = false;
};

}  // namespace cmux_host

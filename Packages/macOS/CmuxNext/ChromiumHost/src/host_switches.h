// The Chromium switches the host starts Chromium with: cmux's set
// (CEFSwitches in cmux, which INITIALIZE carries: the wake-up alignment of
// p14-energy-040 and the idle disables come with it), fitted to the host's own
// message loop. Plain C++, no CEF: the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace cmux_host {

// cmux's external pump slice (CEFSwitches.pumpTimeSliceMicroseconds): the
// host runs CefRunMessageLoop, so there is no external pump pass to slice.
inline constexpr std::string_view kPumpTimeSliceSwitch = "cmux-pump-time-slice-us=";

// Features on in the host beyond cmux's set. TimerSlackMac
// (base/task/task_features.h) gives each delayed task's leeway to the run
// loop timer: MessagePumpCFRunLoopBase::ScheduleDelayedWork calls
// CFRunLoopTimerSetTolerance (base/message_loop/message_pump_apple.mm). The
// host's UI thread runs Chromium's own pump there, as Chrome's browser process
// does, so this is Chrome's timer model on every thread. In process the app's
// UI thread runs CEF's MessagePumpExternal instead, which arms no base timer,
// so cmux keeps the feature behind cefTimerSlack there.
inline constexpr std::string_view kHostEnabledFeatures = "enable-features=TimerSlackMac";

// `app` (cmux's switches, without leading dashes) for the host. The shim
// merges every enable-features entry into CEF's own list
// (CEFShim/src/command_line_switches.h), so the host's entry joins cmux's.
inline std::vector<std::string> HostSwitches(const std::vector<std::string>& app) {
  std::vector<std::string> out;
  out.reserve(app.size() + 1);
  for (const std::string& entry : app) {
    if (entry.compare(0, kPumpTimeSliceSwitch.size(), kPumpTimeSliceSwitch) == 0) continue;
    out.push_back(entry);
  }
  out.emplace_back(kHostEnabledFeatures);
  return out;
}

// The log Chromium writes in the host: the one INITIALIZE names, else the
// spawn's --log-file (`spawn`, ChromiumHostConfiguration). cmux's runtime
// names none in host mode (CEFRuntimeBoot.chromiumLogFile), so the host writes
// the log its supervisor reads the end of when it crashes
// (ChromiumHostSupervisor). Empty: no log.
inline std::string HostLogFile(const std::optional<std::string>& initialize, const std::string& spawn) {
  return initialize && !initialize->empty() ? *initialize : spawn;
}

}  // namespace cmux_host

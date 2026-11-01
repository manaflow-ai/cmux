// Puts cmux's browser-process switches on Chromium's command line through
// cmux_shim::PlanSwitches (command_line_switches.h), for the in-process
// shim (shim_client.mm) and the Chromium host (browser_host_main.mm).
#pragma once

#include <map>
#include <string>
#include <vector>

#include "include/cef_command_line.h"

#include "command_line_switches.h"

namespace cmux_shim {

// Adds `entries` to `command_line` and removes every sandbox-weakening switch
// and guarded feature, also ones the process was started with. Returns the
// names removed (empty almost always), for the caller's log.
inline std::vector<std::string> ApplySwitches(CefRefPtr<CefCommandLine> command_line,
                                              const std::vector<std::string>& entries) {
  CefCommandLine::SwitchMap present;
  command_line->GetSwitches(present);
  std::vector<Switch> existing;
  existing.reserve(present.size());
  for (const auto& [name, value] : present) existing.push_back({name.ToString(), value.ToString()});
  std::vector<std::string> dropped;
  std::vector<Switch> planned = PlanSwitches(existing, entries, &dropped);

  // Removal needs a rebuilt command line; without one, only additions and
  // changed values are appended, as before the guard.
  bool removes = false;
  for (const Switch& s : existing) {
    bool kept = false;
    for (const Switch& p : planned) kept = kept || p.name == s.name;
    removes = removes || !kept;
  }
  if (removes) {
    CefCommandLine::ArgumentList arguments;
    command_line->GetArguments(arguments);
    command_line->Reset();
    for (const Switch& s : planned) {
      if (s.value.empty()) {
        command_line->AppendSwitch(s.name);
      } else {
        command_line->AppendSwitchWithValue(s.name, s.value);
      }
    }
    for (const CefString& argument : arguments) command_line->AppendArgument(argument);
    return dropped;
  }
  for (const Switch& s : planned) {
    bool same = false;
    for (const Switch& e : existing) same = same || e == s;
    if (same) continue;
    if (s.value.empty()) {
      command_line->AppendSwitch(s.name);
    } else {
      command_line->AppendSwitchWithValue(s.name, s.value);
    }
  }
  return dropped;
}

}  // namespace cmux_shim

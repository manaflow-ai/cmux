// How the shim adds cmux's browser-process switches to the command line
// (needs no CEF; scripts/cmux-next/test-shim-switches-cpp.sh compiles it
// alone).
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace cmux_shim {

// Switches whose value is a comma-separated feature list. CEF puts its own
// list on the command line before OnBeforeCommandLineProcessing (features
// that crash Chrome-style initialization, chrome_main_delegate_cef.cc), so
// cmux's entries must join that list: a plain append replaces it.
inline bool IsFeatureListSwitch(std::string_view name) {
  return name == "disable-features" || name == "enable-features";
}

// `existing` followed by the entries of `added` that it does not contain.
// Blank entries and surrounding spaces are dropped; order is kept.
inline std::string MergeFeatureList(std::string_view existing, std::string_view added) {
  std::vector<std::string> entries;
  auto take = [&entries](std::string_view list) {
    size_t start = 0;
    while (start <= list.size()) {
      size_t comma = list.find(',', start);
      if (comma == std::string_view::npos) comma = list.size();
      std::string_view entry = list.substr(start, comma - start);
      while (!entry.empty() && entry.front() == ' ') entry.remove_prefix(1);
      while (!entry.empty() && entry.back() == ' ') entry.remove_suffix(1);
      if (!entry.empty()) {
        bool seen = false;
        for (const std::string& kept : entries) seen = seen || kept == entry;
        if (!seen) entries.emplace_back(entry);
      }
      start = comma + 1;
    }
  };
  take(existing);
  take(added);
  std::string result;
  for (const std::string& entry : entries) {
    if (!result.empty()) result += ',';
    result += entry;
  }
  return result;
}

// Switches that turn off or weaken Chromium's sandbox or site isolation, or
// run a helper through another program. cmux never starts Chromium with one:
// the shim drops each from cmux's own list and from the command line it was
// given (the app's argv in process: `open cmux.app --args --no-sandbox`).
// A compromised GPU or renderer process is the first half of every Chromium
// sandbox escape (CVE-2026-106378, pwn.ai "chrome-escape"); these keep the
// second half closed.
inline bool IsSandboxWeakeningSwitch(std::string_view name) {
  while (!name.empty() && name.front() == '-') name.remove_prefix(1);
  static constexpr std::string_view kSwitches[] = {
      "no-sandbox",
      "disable-gpu-sandbox",
      "disable-renderer-sandbox",
      "disable-setuid-sandbox",
      "disable-seccomp-filter-sandbox",
      "disable-namespace-sandbox",
      "no-zygote-sandbox",
      "single-process",
      "in-process-gpu",
      "disable-web-security",
      "disable-site-isolation-trials",
      "disable-site-isolation-for-policy",
      "allow-running-insecure-content",
      "gpu-launcher",
      "renderer-cmd-prefix",
      "utility-cmd-prefix",
  };
  for (std::string_view known : kSwitches) {
    if (name == known) return true;
  }
  return false;
}

// Features that must stay on: turning one off in `disable-features` weakens
// process isolation or lets the GPU helper act with the app's macOS privacy
// grants (MacDisclaimGpuTccResponsibility, CVE-2026-106378).
inline bool IsGuardedFeature(std::string_view entry) {
  size_t end = entry.find_first_of("<:");
  if (end != std::string_view::npos) entry = entry.substr(0, end);
  while (!entry.empty() && entry.front() == ' ') entry.remove_prefix(1);
  while (!entry.empty() && entry.back() == ' ') entry.remove_suffix(1);
  if (!entry.empty() && entry.front() == '*') entry.remove_prefix(1);
  static constexpr std::string_view kFeatures[] = {
      "MacDisclaimGpuTccResponsibility",
      "SitePerProcess",
      "IsolateOrigins",
      "NetworkServiceSandbox",
  };
  for (std::string_view known : kFeatures) {
    if (entry == known) return true;
  }
  return false;
}

// `list` (a `disable-features` value) without its guarded entries.
inline std::string WithoutGuardedFeatures(std::string_view list) {
  std::string result;
  size_t start = 0;
  while (start <= list.size()) {
    size_t comma = list.find(',', start);
    if (comma == std::string_view::npos) comma = list.size();
    std::string_view entry = list.substr(start, comma - start);
    if (!IsGuardedFeature(entry)) {
      while (!entry.empty() && entry.front() == ' ') entry.remove_prefix(1);
      while (!entry.empty() && entry.back() == ' ') entry.remove_suffix(1);
      if (!entry.empty()) {
        if (!result.empty()) result += ',';
        result += entry;
      }
    }
    start = comma + 1;
  }
  return result;
}

// One switch as the shim puts it on Chromium's command line.
struct Switch {
  std::string name;
  std::string value;  // empty: a switch without a value
  bool operator==(const Switch& other) const { return name == other.name && value == other.value; }
};

// The switches Chromium starts with: `existing` (CEF's and the process's
// own) with cmux's `entries` ("name" or "name=value") added, feature lists
// merged, and every sandbox-weakening switch and guarded feature removed.
// `dropped` (optional) receives the name of each switch or feature removed.
inline std::vector<Switch> PlanSwitches(const std::vector<Switch>& existing,
                                        const std::vector<std::string>& entries,
                                        std::vector<std::string>* dropped = nullptr) {
  std::vector<Switch> result;
  auto put = [&result](std::string name, std::string value) {
    for (Switch& kept : result) {
      if (kept.name == name) {
        kept.value = IsFeatureListSwitch(name) ? MergeFeatureList(kept.value, value) : value;
        return;
      }
    }
    result.push_back({std::move(name), std::move(value)});
  };
  for (const Switch& s : existing) put(s.name, s.value);
  for (const std::string& entry : entries) {
    size_t eq = entry.find('=');
    if (eq == std::string::npos) {
      put(entry, "");
    } else {
      put(entry.substr(0, eq), entry.substr(eq + 1));
    }
  }
  std::vector<Switch> safe;
  for (Switch& s : result) {
    if (IsSandboxWeakeningSwitch(s.name)) {
      if (dropped) dropped->push_back(s.name);
      continue;
    }
    if (s.name == "disable-features") {
      std::string kept = WithoutGuardedFeatures(s.value);
      if (dropped && kept != MergeFeatureList("", s.value)) dropped->push_back("disable-features guarded entry");
      if (kept.empty()) continue;
      s.value = kept;
    }
    safe.push_back(std::move(s));
  }
  return safe;
}

}  // namespace cmux_shim

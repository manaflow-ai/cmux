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

// The app's own Safe Storage keychain item (fork API 25,
// cmux_set_keychain_item): service "cmux Safe Storage", account the bundle
// identifier, so each cmux channel (com.cmuxterm.app, .nightly,
// .nightly.cmux-next) owns its item and is never asked for another channel's.
// The bundle identifier, not the (localizable, renamed before) bundle name:
// it also names the profile folder, so the item changes only when the data
// it encrypts moves too. Empty when Chromium reads no keychain
// (use-mock-keychain) or the bundle has no identifier; Chromium then keeps
// its own default item.
struct SafeStorageItem {
  std::string service;
  std::string account;
};

inline SafeStorageItem SafeStorageItemFor(std::string_view bundle_identifier,
                                          const std::vector<std::string>& switches) {
  for (const std::string& entry : switches) {
    if (entry == "use-mock-keychain") return {};
  }
  while (!bundle_identifier.empty() && bundle_identifier.front() == ' ') bundle_identifier.remove_prefix(1);
  while (!bundle_identifier.empty() && bundle_identifier.back() == ' ') bundle_identifier.remove_suffix(1);
  if (bundle_identifier.empty()) return {};
  return {"cmux Safe Storage", std::string(bundle_identifier)};
}

}  // namespace cmux_shim

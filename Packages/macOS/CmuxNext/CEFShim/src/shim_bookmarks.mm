// The chrome.bookmarks bridge (plans/cmux-next/bookmarks.md section 4; fork
// API 22: cmux_bookmarks_observe, cmux_bookmarks_sync). cmux owns the tree;
// Chromium's model of each persistent profile caches it. Every profile is
// watched once its request context is initialized, and its events reach the
// app as CMUX_SHIM_BOOKMARKS_EVENT. Off-the-record contexts read the regular
// profile's bookmarks in Chromium and are not watched. UI thread only.

#include <map>
#include <memory>
#include <string>

#include "shim_internal.h"

namespace cmux_shim {

namespace {

// Cache path per watched profile; the fork's observer gets the string as ctx.
std::map<std::string, std::unique_ptr<std::string>>& watches() {
  static std::map<std::string, std::unique_ptr<std::string>> map;
  return map;
}

void Forward(void* ctx, const char* json) {
  if (!json) return;
  Emit(CMUX_SHIM_BOOKMARKS_EVENT, 0, 0, 0, 0, json, *static_cast<const std::string*>(ctx));
}

}  // namespace

void WatchBookmarks(const std::string& key) {
  if (!fork_api().bookmarks_observe || key.empty() || key.rfind(kOffTheRecordPrefix, 0) == 0) return;
  auto path = std::make_unique<std::string>(key);
  if (fork_api().bookmarks_observe(key.c_str(), &Forward, path.get())) watches()[key] = std::move(path);
}

void ForgetBookmarkWatch(const std::string& key) {
  auto it = watches().find(key);
  if (it == watches().end()) return;
  // The fork drops the old observer's pending deliveries, so ctx may go now.
  fork_api().bookmarks_observe(key.c_str(), nullptr, nullptr);
  watches().erase(it);
}

void ReleaseBookmarkWatches() {
  for (auto& [key, path] : watches()) fork_api().bookmarks_observe(key.c_str(), nullptr, nullptr);
  watches().clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_bookmarks_sync(const char* profile_cache_path, const char* tree_json) {
  if (!fork_api().bookmarks_sync || !profile_cache_path || !*profile_cache_path || !tree_json) return -1;
  return fork_api().bookmarks_sync(profile_cache_path, tree_json);
}

}  // extern "C"

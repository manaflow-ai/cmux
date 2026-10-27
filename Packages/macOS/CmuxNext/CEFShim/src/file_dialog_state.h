// The shim's file chooser bookkeeping, with no CEF
// (scripts/cmux-next/test-shim-file-dialog-cpp.sh compiles it alone).
// A page's <input type=file> goes to the host app (CMUX_SHIM_FILE_DIALOG);
// the host answers through cmux_shim_file_dialog_answer. Each request is
// answered at most once; a closed or crashed browser cancels its requests.
#pragma once

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace cmux_shim {

// Pending requests by dialog id (1, 2, 3, ... never reused), with the
// browser each belongs to. Callback is CefRefPtr<CefFileDialogCallback> in
// the shim, a fake in the test.
template <typename Callback>
class FileDialogs {
 public:
  int Add(int browser_id, Callback callback) {
    const int id = ++last_id_;
    pending_.emplace(id, Entry{browser_id, std::move(callback)});
    return id;
  }

  // The request's callback, removed; nullopt when it is unknown or answered.
  std::optional<Callback> Take(int dialog_id) {
    auto it = pending_.find(dialog_id);
    if (it == pending_.end()) return std::nullopt;
    Callback callback = std::move(it->second.callback);
    pending_.erase(it);
    return callback;
  }

  // Every pending request of the browser, removed (it closed or crashed).
  std::vector<Callback> TakeAll(int browser_id) {
    std::vector<Callback> taken;
    for (auto it = pending_.begin(); it != pending_.end();) {
      if (it->second.browser_id == browser_id) {
        taken.push_back(std::move(it->second.callback));
        it = pending_.erase(it);
      } else {
        ++it;
      }
    }
    return taken;
  }

 private:
  struct Entry {
    int browser_id;
    Callback callback;
  };
  int last_id_ = 0;
  std::map<int, Entry> pending_;
};

// The host's answer: absolute paths, one per line. Empty means cancel;
// relative paths are dropped (the host only gives panel URLs).
inline std::vector<std::string> SplitPaths(std::string_view text) {
  std::vector<std::string> paths;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string_view::npos) end = text.size();
    std::string_view line = text.substr(start, end - start);
    if (!line.empty() && line.front() == '/') paths.emplace_back(line);
    start = end + 1;
  }
  return paths;
}

// A single-file mode (open, save) keeps the first path only.
inline std::vector<std::string> KeepForMode(std::vector<std::string> paths, bool multiple) {
  if (!multiple && paths.size() > 1) paths.resize(1);
  return paths;
}

// Chromium's accept filters (MIME types, ".ext") for the event, one per line.
inline std::string JoinFilters(const std::vector<std::string>& filters) {
  std::string joined;
  for (const auto& filter : filters) {
    if (!joined.empty()) joined.push_back('\n');
    joined += filter;
  }
  return joined;
}

}  // namespace cmux_shim

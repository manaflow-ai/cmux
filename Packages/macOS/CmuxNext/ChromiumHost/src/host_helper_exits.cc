// The plain C++ half of host_helper_exits.h: argv parsing and the table of
// followed children. host_helper_watch.mm is the kqueue half.

#include "host_helper_exits.h"

#include <utility>

namespace cmux_host {

std::optional<HelperIdentity> HelperIdentityOf(const std::vector<std::string>& argv) {
  constexpr std::string_view kType = "--type=";
  constexpr std::string_view kSubType = "--utility-sub-type=";
  HelperIdentity identity;
  for (const std::string& argument : argv) {
    const std::string_view text(argument);
    if (text.substr(0, kType.size()) == kType) {
      identity.type = std::string(text.substr(kType.size()));
    } else if (text.substr(0, kSubType.size()) == kSubType) {
      identity.sub_type = std::string(text.substr(kSubType.size()));
    } else if (text == "--extension-process") {
      identity.extension = true;
    }
  }
  if (identity.type.empty()) return std::nullopt;
  return identity;
}

std::vector<std::string> ProcArgs(std::string_view buffer) {
  constexpr size_t kIntSize = 4;
  if (buffer.size() <= kIntSize) return {};
  uint32_t bits = 0;
  for (size_t i = 0; i < kIntSize; ++i) bits |= static_cast<uint32_t>(static_cast<uint8_t>(buffer[i])) << (8 * i);
  const auto argc = static_cast<int32_t>(bits);
  if (argc <= 0) return {};
  size_t index = kIntSize;
  // The exec path, then the NUL padding after it.
  while (index < buffer.size() && buffer[index] != '\0') ++index;
  while (index < buffer.size() && buffer[index] == '\0') ++index;
  std::vector<std::string> argv;
  while (index < buffer.size() && argv.size() < static_cast<size_t>(argc)) {
    const size_t start = index;
    while (index < buffer.size() && buffer[index] != '\0') ++index;
    argv.emplace_back(buffer.substr(start, index - start));
    ++index;
  }
  return argv;
}

void HelperTable::Watch(int32_t pid, std::optional<HelperIdentity> identity) {
  children_.insert_or_assign(pid, std::move(identity));
}

void HelperTable::Execed(int32_t pid, std::optional<HelperIdentity> identity) {
  auto found = children_.find(pid);
  if (found != children_.end()) found->second = std::move(identity);
}

std::optional<HelperExit> HelperTable::Exited(int32_t pid, int32_t status) {
  auto found = children_.find(pid);
  if (found == children_.end()) return std::nullopt;
  std::optional<HelperIdentity> identity = std::move(found->second);
  children_.erase(found);
  if (!identity) return std::nullopt;
  return HelperExit{pid, status, std::move(*identity)};
}

}  // namespace cmux_host

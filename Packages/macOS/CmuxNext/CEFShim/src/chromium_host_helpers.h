// What the Chromium host reports about its own helper processes (renderer,
// GPU, utility): the payloads of kHelperStart, kHelperExit and
// kRendererClients (chromium_host_wire.h). Needs no CEF and no macOS API, so
// scripts/cmux-next/test-chromium-host-wire-cpp.sh tests it on any machine;
// browser_host_main.mm does the kqueue and sysctl part. The Swift side reads
// the same payloads in ChromiumHostProcessMirror.swift.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace cmux_host {

// A helper's `--type`, `--utility-sub-type`, `--extension-process` and
// `--renderer-client-id`, read from its argv (as CEFHelperIdentity does in
// cmux for in-process helpers).
struct HelperIdentity {
  std::string type;
  std::string sub_type;
  bool extension = false;
  int32_t renderer_client_id = 0;
};

// The decimal number `text` starts with, up to `end`; 0 when it is not one.
inline int32_t ParsePositive(const std::string& text, size_t begin, size_t end) {
  if (begin >= end || end > text.size()) return 0;
  int64_t value = 0;
  for (size_t i = begin; i < end; ++i) {
    if (text[i] < '0' || text[i] > '9') return 0;
    value = value * 10 + (text[i] - '0');
    if (value > 100000000) return 0;
  }
  return static_cast<int32_t>(value);
}

// False for a process that is not a Chromium helper (no `--type=`), or one
// that has not exec'd yet (it still has its parent's argv).
inline bool ParseHelperArgs(const std::vector<std::string>& argv, HelperIdentity* out) {
  HelperIdentity identity;
  for (const std::string& argument : argv) {
    if (argument.rfind("--type=", 0) == 0) {
      identity.type = argument.substr(7);
    } else if (argument.rfind("--utility-sub-type=", 0) == 0) {
      identity.sub_type = argument.substr(19);
    } else if (argument == "--extension-process") {
      identity.extension = true;
    } else if (argument.rfind("--renderer-client-id=", 0) == 0) {
      identity.renderer_client_id = ParsePositive(argument, 21, argument.size());
    }
  }
  if (identity.type.empty()) return false;
  *out = identity;
  return true;
}

// argv from a KERN_PROCARGS2 buffer: argc (int32), the exec path, NUL
// padding, then argc NUL-terminated arguments.
inline std::vector<std::string> ParseProcArgs(const uint8_t* buffer, size_t size) {
  std::vector<std::string> result;
  if (!buffer || size <= sizeof(int32_t)) return result;
  int32_t argc = 0;
  for (size_t i = 0; i < sizeof(int32_t); ++i) argc |= static_cast<int32_t>(buffer[i]) << (8 * i);
  if (argc <= 0) return result;
  size_t index = sizeof(int32_t);
  while (index < size && buffer[index] != 0) ++index;
  while (index < size && buffer[index] == 0) ++index;
  while (index < size && result.size() < static_cast<size_t>(argc)) {
    const size_t start = index;
    while (index < size && buffer[index] != 0) ++index;
    result.emplace_back(reinterpret_cast<const char*>(buffer + start), index - start);
    ++index;
  }
  return result;
}

// The text payload of kHelperStart and kHelperExit: the type, then "\n" and
// the utility sub type when there is one.
inline std::string HelperPayload(const HelperIdentity& identity) {
  return identity.sub_type.empty() ? identity.type : identity.type + "\n" + identity.sub_type;
}

// The renderer client id of a frame identifier: "<render process host id>-<frame token>"
// (frame_util::MakeFrameIdentifier); the host id is the renderer's `--renderer-client-id`.
// 0 when `identifier` has no such prefix.
inline int32_t RendererClientOfFrame(const std::string& identifier) {
  const size_t dash = identifier.find('-');
  if (dash == std::string::npos) return 0;
  return ParsePositive(identifier, 0, dash);
}

// Distinct renderer client ids of a page's frames, in first-seen order.
inline std::vector<int32_t> RendererClients(const std::vector<std::string>& frame_identifiers) {
  std::vector<int32_t> ids;
  for (const std::string& identifier : frame_identifiers) {
    const int32_t id = RendererClientOfFrame(identifier);
    if (id <= 0) continue;
    bool seen = false;
    for (int32_t known : ids) seen = seen || known == id;
    if (!seen) ids.push_back(id);
  }
  return ids;
}

// The payload of kRendererClients: each id as a little-endian int32.
inline std::string EncodeClientIDs(const std::vector<int32_t>& ids) {
  std::string bytes;
  bytes.reserve(ids.size() * 4);
  for (int32_t id : ids) {
    const uint32_t value = static_cast<uint32_t>(id);
    for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<char>((value >> (8 * i)) & 0xff));
  }
  return bytes;
}

// The signal that ended a process from its raw wait status, 0 when it exited
// (WTERMSIG / WIFSIGNALED without <sys/wait.h>).
inline int32_t TerminatingSignal(int32_t status) {
  const int32_t low = status & 0x7f;
  return low == 0 || low == 0x7f ? 0 : low;
}

// The exit code of a process that exited (WEXITSTATUS); 0 when a signal ended it.
inline int32_t ExitCode(int32_t status) {
  return TerminatingSignal(status) ? 0 : (status >> 8) & 0xff;
}

}  // namespace cmux_host

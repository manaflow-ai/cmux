// The app's Energy Saver in the Chromium Host (plans/cmux-next/chrome-parity/
// p14-energy.md, task 045). The host is the page's browser process, so the
// saver's browser-side work runs there, as Chrome's BatterySaverModeManager
// runs it in its browser process
// (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc,
// NotifyBatterySaverModeChanged): cmux sends kOpEnergySaver on each edge of
// its saver, and the host calls its shim's cmux_shim_set_energy_saver, which
// calls the fork's cmux_cef_set_energy_saver (frame sinks at
// 30 Hz except the exempt scheme's pages, 32 ms wake alignment, battery saver
// mode in every child process).
//
// The op is not in the generated table: it is versioned on its own, so a host
// and a cmux of different builds of this file still agree on it.
//   i32 version (kEnergySaverVersion), then version 1's fields:
//   i32 enabled (0 or 1), str exempt_scheme (NULL: no page is exempt)
// A later version only appends fields: a host reads the fields of the versions
// it knows and leaves the rest. Version 0 or below is a malformed op.
//
// A host whose fork has the saver lists kEnergySaverHelloName in its HELLO;
// cmux's remote shim answers cmux_shim_set_energy_saver from that list. A host
// without it takes the op and changes nothing.
//
// Plain C++, no CEF: the tests build it on Linux
// (scripts/cmux-next/tests/chromium-host-dispatch.test.sh).
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "chromium_host_tlv.h"

namespace cmux_host {

// Next to kOpPageResize (host_resize.h): not in the generated op table.
inline constexpr uint16_t kOpEnergySaver = 0x800b;
// The kOpEnergySaver layout this side writes.
inline constexpr int32_t kEnergySaverVersion = 1;
// The name a host lists in its HELLO's exports when its fork has
// cmux_cef_set_energy_saver (CEFHostStart's hostExports in cmux).
inline constexpr char kEnergySaverHelloName[] = "cmux_host_energy_saver";

// kOpEnergySaver's fields.
struct EnergySaver {
  bool enabled = false;
  std::optional<std::string> exempt_scheme;

  bool operator==(const EnergySaver& other) const = default;
};

// Writes kOpEnergySaver's fields for `saver` (the remote shim's side).
inline void WriteEnergySaver(const EnergySaver& saver, control::TlvWriter* w) {
  w->I32(kEnergySaverVersion);
  w->I32(saver.enabled ? 1 : 0);
  w->Str(saver.exempt_scheme ? saver.exempt_scheme->c_str() : nullptr);
}

// The op's fields; nullopt for a malformed op (no version or one below 1,
// wrong types, enabled not 0 or 1, version 1 with more fields).
inline std::optional<EnergySaver> DecodeEnergySaver(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  const int32_t enabled = r.I32();
  EnergySaver saver;
  saver.exempt_scheme = r.Str();
  if (!r.ok() || version < 1 || (enabled != 0 && enabled != 1)) return std::nullopt;
  if (version == kEnergySaverVersion && !r.AtEnd()) return std::nullopt;
  saver.enabled = enabled == 1;
  return saver;
}

}  // namespace cmux_host

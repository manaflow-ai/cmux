// The color chooser, device choosers and screen-share picker of the Chromium
// Host in cmux (plans/cmux-next/chrome-parity/p01-process.md),
// both ends of the wire. Fork API 31 (task 227) hands these
// to the embedder as data answered by token, because Chromium's own windows
// for them would open in the host, which shows no window. The host installs
// the shim's handler (cmux_shim_set_color_chooser_handler,
// _set_device_chooser_handler, _set_desktop_media_handler) while cmux's
// client has one set, and pushes each of its events; the remote shim's client
// keeps cmux's fn and calls it with the fork's struct rebuilt from the push.
// cmux's answers are the generated posts (cmux_shim_color_chooser_choose and
// the rest). Chrome splits the same way between its browser process and the
// app shim: ColorChooserMac sends the panel's colors over
// blink.mojom.ColorChooserClient, and the chooser bubble reads its rows from
// permissions::ChooserController
// (chrome/browser/ui/views/device_chooser_content_view.cc).
//
// Wire:
//   cmux -> host  the setter's generated op id (kOpSetColorChooserHandler,
//                 kOpSetDeviceChooserHandler, kOpSetDesktopMediaHandler) with
//                 i32 installed (0 or 1): no marshaller (the export is
//                 `local`), the host's own case. Sent when it differs from
//                 what the host last took, and again at each host's HELLO.
//   host -> cmux  kOpEvent of kind CMUX_SHIM_COLOR_CHOOSER, _DEVICE_CHOOSER or
//                 _DESKTOP_MEDIA (EncodePayloadEvent): request = the handler's
//                 event (CMUX_SHIM_COLOR_CHOOSER_OPEN ...), a = token, b = the
//                 color (color chooser), s1 = the payload below as bytes (an
//                 EncodeFields body; "" for the events with no data).
//   payloads      color OPEN:     i32 count, then per suggestion u32 color,
//                                 str label
//                 device UPDATE:  str origin, title, no_options_text,
//                                 ok_label; i32 show_signal_strength,
//                                 show_rescan, allow_multiple, initialized,
//                                 refreshing, adapter_enabled,
//                                 adapter_authorized,
//                                 both_buttons_always_enabled; i32 count, then
//                                 per row str name, i32 signal_strength,
//                                 connected, paired
//                 media OPEN:     str app_name; i32 source_types,
//                                 preferred_source, request_audio
// Strings are cut to kMaxText bytes and lists to what fits kMaxPayload (a
// prefix, so an answer's row indices stay the fork's). An unreadable fork
// struct (NULL, or older than this copy) goes as an empty one.
//
// No CEF, no AppKit: the host (host_dispatch.mm), the client
// (../client/remote_shim_choosers.mm) and tests/host_choosers_test.cpp
// compile it on any machine.
#pragma once

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "chromium_host_tlv.h"
#include "cmux_cef_shim.h"

namespace cmux_host::choosers {

// The three handlers, in the order of their ops.
enum Handler : int {
  kColor = 0,
  kDevice = 1,
  kDesktopMedia = 2,
};
inline constexpr int kHandlerCount = 3;

// Bytes of one string and of one payload: one event stays far under the
// control frame's kMaxBody.
inline constexpr size_t kMaxText = 1024;
inline constexpr size_t kMaxPayload = 48 * 1024;

// include/cef_cmux.h's structs (manaflow-ai/cef cp/p01-process-227). Fields
// are only appended; `size` is the fork's sizeof.
struct ForkColorChooser {
  int size;
  int64_t token;
  uint32_t color;
  const uint32_t* suggestion_colors;
  const char* const* suggestion_labels;
  int suggestion_count;
};
struct ForkDeviceOption {
  const char* name;
  int signal_strength;  // 0-4, -1 when not shown
  int connected;
  int paired;
};
struct ForkDeviceChooser {
  int size;
  int64_t token;
  const char* origin;
  const char* title;
  const char* no_options_text;
  const char* ok_label;
  int show_signal_strength;
  int show_rescan;
  int allow_multiple;
  int initialized;
  int refreshing;
  int adapter_enabled;
  int adapter_authorized;
  int both_buttons_always_enabled;
  const ForkDeviceOption* options;
  int option_count;
};
struct ForkDesktopMediaRequest {
  int size;
  int64_t token;
  const char* app_name;
  int source_types;
  int preferred_source;
  int request_audio;
};
static_assert(sizeof(void*) != 8 || sizeof(ForkColorChooser) == 48, "the fork's API 31 layout on LP64");
static_assert(sizeof(void*) != 8 || sizeof(ForkDeviceOption) == 24, "the fork's API 31 layout on LP64");
static_assert(sizeof(void*) != 8 || sizeof(ForkDeviceChooser) == 96, "the fork's API 31 layout on LP64");
static_assert(sizeof(void*) != 8 || sizeof(ForkDesktopMediaRequest) == 40, "the fork's API 31 layout on LP64");
// The offsets cmux's Swift reads (CEFS/ChromiumHost/ChromiumHostChooserData.swift).
static_assert(sizeof(void*) != 8 || (offsetof(ForkColorChooser, token) == 8 && offsetof(ForkColorChooser, color) == 16 &&
                                     offsetof(ForkColorChooser, suggestion_colors) == 24 &&
                                     offsetof(ForkColorChooser, suggestion_labels) == 32 &&
                                     offsetof(ForkColorChooser, suggestion_count) == 40),
              "ChromiumHostChooserData.swift's color chooser offsets");
static_assert(sizeof(void*) != 8 || (offsetof(ForkDeviceOption, signal_strength) == 8 &&
                                     offsetof(ForkDeviceOption, connected) == 12 && offsetof(ForkDeviceOption, paired) == 16),
              "ChromiumHostChooserData.swift's device row offsets");
static_assert(sizeof(void*) != 8 || (offsetof(ForkDeviceChooser, origin) == 16 && offsetof(ForkDeviceChooser, ok_label) == 40 &&
                                     offsetof(ForkDeviceChooser, show_signal_strength) == 48 &&
                                     offsetof(ForkDeviceChooser, both_buttons_always_enabled) == 76 &&
                                     offsetof(ForkDeviceChooser, options) == 80 &&
                                     offsetof(ForkDeviceChooser, option_count) == 88),
              "ChromiumHostChooserData.swift's device chooser offsets");
static_assert(sizeof(void*) != 8 || (offsetof(ForkDesktopMediaRequest, app_name) == 16 &&
                                     offsetof(ForkDesktopMediaRequest, source_types) == 24 &&
                                     offsetof(ForkDesktopMediaRequest, preferred_source) == 28 &&
                                     offsetof(ForkDesktopMediaRequest, request_audio) == 32),
              "ChromiumHostChooserData.swift's media request offsets");

// The event kind a handler's pushes have, and back; nullopt for any other kind.
inline int EventKindOf(Handler handler) {
  switch (handler) {
    case kColor:
      return CMUX_SHIM_COLOR_CHOOSER;
    case kDevice:
      return CMUX_SHIM_DEVICE_CHOOSER;
    case kDesktopMedia:
      return CMUX_SHIM_DESKTOP_MEDIA;
  }
  return 0;
}
inline std::optional<Handler> HandlerOfEventKind(int kind) {
  switch (kind) {
    case CMUX_SHIM_COLOR_CHOOSER:
      return kColor;
    case CMUX_SHIM_DEVICE_CHOOSER:
      return kDevice;
    case CMUX_SHIM_DESKTOP_MEDIA:
      return kDesktopMedia;
    default:
      return std::nullopt;
  }
}

// The handler's event that opens or updates a request (it has a payload) and
// the one that ends it.
inline int OpenEventOf(Handler handler) {
  switch (handler) {
    case kColor:
      return CMUX_SHIM_COLOR_CHOOSER_OPEN;
    case kDevice:
      return CMUX_SHIM_DEVICE_CHOOSER_UPDATE;
    case kDesktopMedia:
      return CMUX_SHIM_DESKTOP_MEDIA_OPEN;
  }
  return 0;
}
inline int EndEventOf(Handler handler) {
  switch (handler) {
    case kColor:
      return CMUX_SHIM_COLOR_CHOOSER_END;
    case kDevice:
      return CMUX_SHIM_DEVICE_CHOOSER_CLOSE;
    case kDesktopMedia:
      return CMUX_SHIM_DESKTOP_MEDIA_CLOSE;
  }
  return 0;
}

// The setter's i32 installed field (the client's side) and the host's read of
// it; nullopt for a malformed op.
inline void WriteInstalled(bool installed, control::TlvWriter* w) { w->I32(installed ? 1 : 0); }
inline std::optional<bool> ReadInstalled(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t installed = r.I32();
  if (!r.ok() || !r.AtEnd() || (installed != 0 && installed != 1)) return std::nullopt;
  return installed == 1;
}

namespace detail {

// `text` cut to kMaxText bytes, never inside a UTF-8 sequence; "" for NULL.
inline std::string Cut(const char* text) {
  if (text == nullptr) return std::string();
  std::string_view view(text);
  if (view.size() <= kMaxText) return std::string(view);
  size_t end = kMaxText;
  while (end > 0 && (static_cast<uint8_t>(view[end]) & 0xC0) == 0x80) --end;
  return std::string(view.substr(0, end));
}

// The fork's struct when it is at least this copy's size, else NULL.
template <typename T>
const T* Readable(const void* fork) {
  const auto* value = static_cast<const T*>(fork);
  return value != nullptr && value->size >= static_cast<int>(sizeof(T)) ? value : nullptr;
}

// Bytes a list row adds to the payload (field headers and the text).
inline size_t RowSize(size_t text_bytes, int numbers) {
  return (control::kFieldHeaderSize + text_bytes) + static_cast<size_t>(numbers) * (control::kFieldHeaderSize + 8);
}

// Fields with the list count `count` put before the rows (at `count_at`).
inline bool Finish(std::vector<control::Field> head, size_t count_at, int32_t count,
                   std::vector<control::Field> rows, std::string* out) {
  head[count_at] = control::Field::I32(control::kTagValue, count);
  head.insert(head.end(), std::make_move_iterator(rows.begin()), std::make_move_iterator(rows.end()));
  out->clear();
  return control::EncodeFields(head, out);
}

}  // namespace detail

// Host side: the payload of a COLOR_CHOOSER_OPEN for the fork's
// cmux_color_chooser_t. False only when the encoding fails (never within the
// bounds).
inline bool EncodeColorChooser(const void* fork, std::string* out) {
  const ForkColorChooser* chooser = detail::Readable<ForkColorChooser>(fork);
  control::TlvWriter head;
  head.I32(0);  // the count, set below
  control::TlvWriter rows;
  int32_t count = 0;
  size_t bytes = 0;
  const int listed = chooser != nullptr && chooser->suggestion_colors != nullptr ? chooser->suggestion_count : 0;
  for (int i = 0; i < listed; ++i) {
    const std::string label = detail::Cut(chooser->suggestion_labels != nullptr ? chooser->suggestion_labels[i] : nullptr);
    bytes += detail::RowSize(label.size(), 1);
    if (bytes > kMaxPayload) break;
    rows.U32(chooser->suggestion_colors[i]);
    rows.Str(label.c_str());
    ++count;
  }
  return detail::Finish(head.Take(), 0, count, rows.Take(), out);
}

// Host side: the payload of a DEVICE_CHOOSER_UPDATE for the fork's
// cmux_device_chooser_t.
inline bool EncodeDeviceChooser(const void* fork, std::string* out) {
  const ForkDeviceChooser* state = detail::Readable<ForkDeviceChooser>(fork);
  const ForkDeviceChooser empty{};
  const ForkDeviceChooser& s = state != nullptr ? *state : empty;
  control::TlvWriter head;
  size_t bytes = 0;
  for (const char* text : {s.origin, s.title, s.no_options_text, s.ok_label}) {
    const std::string cut = detail::Cut(text);
    bytes += detail::RowSize(cut.size(), 0);
    head.Str(cut.c_str());
  }
  for (int flag : {s.show_signal_strength, s.show_rescan, s.allow_multiple, s.initialized, s.refreshing,
                   s.adapter_enabled, s.adapter_authorized, s.both_buttons_always_enabled}) {
    head.I32(flag);
  }
  const size_t count_at = head.fields().size();
  head.I32(0);  // the count, set below
  control::TlvWriter rows;
  int32_t count = 0;
  const int listed = s.options != nullptr ? s.option_count : 0;
  for (int i = 0; i < listed; ++i) {
    const ForkDeviceOption& option = s.options[i];
    const std::string name = detail::Cut(option.name);
    bytes += detail::RowSize(name.size(), 3);
    if (bytes > kMaxPayload) break;
    rows.Str(name.c_str());
    rows.I32(option.signal_strength);
    rows.I32(option.connected);
    rows.I32(option.paired);
    ++count;
  }
  return detail::Finish(head.Take(), count_at, count, rows.Take(), out);
}

// Host side: the payload of a DESKTOP_MEDIA_OPEN for the fork's
// cmux_desktop_media_request_t.
inline bool EncodeDesktopMedia(const void* fork, std::string* out) {
  const ForkDesktopMediaRequest* request = detail::Readable<ForkDesktopMediaRequest>(fork);
  const ForkDesktopMediaRequest empty{};
  const ForkDesktopMediaRequest& r = request != nullptr ? *request : empty;
  control::TlvWriter w;
  w.Str(detail::Cut(r.app_name).c_str());
  w.I32(r.source_types);
  w.I32(r.preferred_source);
  w.I32(r.request_audio);
  out->clear();
  return w.Encode(out);
}

// A handler event as kOpEvent's fields, with `payload` as s1's bytes (the
// generated EncodeEvent takes C strings, which a payload is not).
inline void EncodePayloadEvent(control::TlvWriter& w, int kind, int32_t browser, int32_t request, int64_t a,
                               int64_t b, const std::string& payload) {
  w.I32(kind);
  w.I32(browser);
  w.I32(request);
  w.I64(a);
  w.I64(b);
  w.Bytes(payload.data(), payload.size());
  w.Str(nullptr);
}

// Client side: a decoded payload that owns its storage; fork() is the fork's
// struct over it, valid while this lives. Decode returns nullptr for a
// payload that is not its encoder's.

class ColorChooserData {
 public:
  static std::unique_ptr<ColorChooserData> Decode(std::string_view payload, int64_t token, uint32_t color) {
    std::vector<control::Field> fields;
    if (!control::DecodeFields(payload, &fields)) return nullptr;
    control::TlvReader r(std::move(fields));
    const int32_t count = r.I32();
    if (!r.ok() || count < 0) return nullptr;
    std::unique_ptr<ColorChooserData> data(new ColorChooserData());
    for (int32_t i = 0; i < count && r.ok(); ++i) {
      data->colors_.push_back(r.U32());
      data->labels_.push_back(r.Str().value_or(std::string()));
    }
    if (!r.ok() || !r.AtEnd()) return nullptr;
    for (const std::string& label : data->labels_) data->label_pointers_.push_back(label.c_str());
    data->fork_ = ForkColorChooser{static_cast<int>(sizeof(ForkColorChooser)), token, color,
                                   data->colors_.empty() ? nullptr : data->colors_.data(),
                                   data->label_pointers_.empty() ? nullptr : data->label_pointers_.data(),
                                   static_cast<int>(data->colors_.size())};
    return data;
  }
  const ForkColorChooser* fork() const { return &fork_; }

 private:
  ColorChooserData() = default;
  std::vector<uint32_t> colors_;
  std::vector<std::string> labels_;
  std::vector<const char*> label_pointers_;  // into labels_, which no longer grows
  ForkColorChooser fork_{};
};

class DeviceChooserData {
 public:
  static std::unique_ptr<DeviceChooserData> Decode(std::string_view payload, int64_t token) {
    std::vector<control::Field> fields;
    if (!control::DecodeFields(payload, &fields)) return nullptr;
    control::TlvReader r(std::move(fields));
    std::unique_ptr<DeviceChooserData> data(new DeviceChooserData());
    for (std::string& text : data->texts_) text = r.Str().value_or(std::string());
    ForkDeviceChooser& s = data->fork_;
    s.size = static_cast<int>(sizeof(ForkDeviceChooser));
    s.token = token;
    for (int* flag : {&s.show_signal_strength, &s.show_rescan, &s.allow_multiple, &s.initialized, &s.refreshing,
                      &s.adapter_enabled, &s.adapter_authorized, &s.both_buttons_always_enabled}) {
      *flag = r.I32();
    }
    const int32_t count = r.I32();
    if (!r.ok() || count < 0) return nullptr;
    for (int32_t i = 0; i < count && r.ok(); ++i) {
      data->names_.push_back(r.Str().value_or(std::string()));
      ForkDeviceOption option{};
      option.signal_strength = r.I32();
      option.connected = r.I32();
      option.paired = r.I32();
      data->options_.push_back(option);
    }
    if (!r.ok() || !r.AtEnd()) return nullptr;
    for (size_t i = 0; i < data->options_.size(); ++i) data->options_[i].name = data->names_[i].c_str();
    s.origin = data->texts_[0].c_str();
    s.title = data->texts_[1].c_str();
    s.no_options_text = data->texts_[2].c_str();
    s.ok_label = data->texts_[3].c_str();
    s.options = data->options_.empty() ? nullptr : data->options_.data();
    s.option_count = static_cast<int>(data->options_.size());
    return data;
  }
  const ForkDeviceChooser* fork() const { return &fork_; }

 private:
  DeviceChooserData() = default;
  std::string texts_[4];  // origin, title, no_options_text, ok_label
  std::vector<std::string> names_;
  std::vector<ForkDeviceOption> options_;  // names point into names_
  ForkDeviceChooser fork_{};
};

class DesktopMediaData {
 public:
  static std::unique_ptr<DesktopMediaData> Decode(std::string_view payload, int64_t token) {
    std::vector<control::Field> fields;
    if (!control::DecodeFields(payload, &fields)) return nullptr;
    control::TlvReader r(std::move(fields));
    std::unique_ptr<DesktopMediaData> data(new DesktopMediaData());
    data->app_name_ = r.Str().value_or(std::string());
    ForkDesktopMediaRequest& request = data->fork_;
    request.size = static_cast<int>(sizeof(ForkDesktopMediaRequest));
    request.token = token;
    request.source_types = r.I32();
    request.preferred_source = r.I32();
    request.request_audio = r.I32();
    if (!r.ok() || !r.AtEnd()) return nullptr;
    request.app_name = data->app_name_.c_str();
    return data;
  }
  const ForkDesktopMediaRequest* fork() const { return &fork_; }

 private:
  DesktopMediaData() = default;
  std::string app_name_;
  ForkDesktopMediaRequest fork_{};
};

}  // namespace cmux_host::choosers

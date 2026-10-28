// The remote shim's chooser handlers (remote_shim_choosers.h).
// Plain C++ (no Objective-C), so
// tests/remote_shim_choosers_test.cpp compiles it on any machine
// (scripts/cmux-next/tests/remote-shim-choosers.test.sh).

#include "remote_shim_choosers.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <memory>
#include <vector>

#if defined(__APPLE__)
#include <pthread.h>
#elif defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace cmux_remote::choosers {
namespace {

using cmux_host::choosers::ColorChooserData;
using cmux_host::choosers::DesktopMediaData;
using cmux_host::choosers::DeviceChooserData;
using cmux_host::choosers::Handler;
using cmux_host::choosers::kHandlerCount;

using ColorFn = void (*)(void* context, int event, int browser_id, int64_t token, unsigned int color,
                         const void* data);
using ChooserFn = void (*)(void* context, int event, int browser_id, int64_t token, const void* data);

// Requests kept per handler for Detach's ends: the app answers by a generated
// post this file does not see, so an answered one stays until the bound pushes
// it out (the app ignores an end for a token it answered).
constexpr size_t kMaxOpen = 256;

// As Chrome's DCHECK_CALLED_ON_VALID_SEQUENCE: no lock, only the main thread.
void AssertMainThread() {
#if defined(__APPLE__)
  assert(pthread_main_np() != 0);
#elif defined(__linux__)
  assert(syscall(SYS_gettid) == getpid());
#endif
}

// One handler: cmux's fn (a ColorFn for the color chooser, else a ChooserFn),
// the requests it has open, and what the attached host last took.
struct Slot {
  void* fn = nullptr;
  void* context = nullptr;
  std::vector<int64_t> open;
  bool sent_installed = false;

  bool IsOpen(int64_t token) const { return std::find(open.begin(), open.end(), token) != open.end(); }
  void Opened(int64_t token) {
    if (IsOpen(token)) return;
    if (open.size() >= kMaxOpen) open.erase(open.begin());
    open.push_back(token);
  }
  bool Closed(int64_t token) {
    const auto it = std::find(open.begin(), open.end(), token);
    if (it == open.end()) return false;
    open.erase(it);
    return true;
  }
};

class Choosers {
 public:
  void Attach(const Transport* transport) {
    transport_ = transport;
    for (int i = 0; i < kHandlerCount; ++i) Sync(static_cast<Handler>(i));
  }

  void Detach() {
    transport_ = nullptr;
    for (int i = 0; i < kHandlerCount; ++i) {
      Slot& slot = slots_[i];
      slot.sent_installed = false;
      EndOpen(static_cast<Handler>(i), slot.fn, slot.context);
    }
  }

  // The in-process shim's contract: the old fn's open requests end at the old
  // fn when it is removed or replaced. The host's fork ends them too (a
  // removal, or a replacement sent as removed then installed), and its ends
  // then name tokens no longer open here, so nothing calls the old fn twice.
  int Set(Handler handler, void* fn, void* context) {
    Slot& slot = slots_[handler];
    const bool replaced = slot.fn != nullptr && fn != nullptr && (fn != slot.fn || context != slot.context);
    if (slot.fn != nullptr && (fn == nullptr || replaced)) EndOpen(handler, slot.fn, slot.context);
    slot.fn = fn;
    slot.context = fn != nullptr ? context : nullptr;
    if (replaced && slot.sent_installed && Send(handler, false)) slot.sent_installed = false;
    Sync(handler);
    return 1;
  }

  bool Deliver(int kind, int browser, int request, int64_t token, int64_t b, std::string_view payload) {
    const std::optional<Handler> handler = cmux_host::choosers::HandlerOfEventKind(kind);
    if (!handler) return false;
    Slot& slot = slots_[*handler];
    if (request == cmux_host::choosers::OpenEventOf(*handler)) return Open(*handler, slot, browser, token, b, payload);
    if (request == cmux_host::choosers::EndEventOf(*handler)) {
      // Not after the app's own end: an end of a token Detach or a removal already ended is dropped.
      if (slot.Closed(token)) CallEnd(*handler, slot.fn, slot.context, token);
      return true;
    }
    if (*handler == cmux_host::choosers::kColor && request == CMUX_SHIM_COLOR_CHOOSER_SET_COLOR) {
      if (slot.fn != nullptr && slot.IsOpen(token)) {
        reinterpret_cast<ColorFn>(slot.fn)(slot.context, request, browser, token, static_cast<uint32_t>(b), nullptr);
      }
      return true;
    }
    return false;
  }

 private:
  bool Open(Handler handler, Slot& slot, int browser, int64_t token, int64_t b, std::string_view payload) {
    const int event = cmux_host::choosers::OpenEventOf(handler);
    // Decoded before the fn check: a payload that is not the encoder's is a malformed frame either way.
    switch (handler) {
      case cmux_host::choosers::kColor: {
        const auto color = static_cast<uint32_t>(b);
        const std::unique_ptr<ColorChooserData> data = ColorChooserData::Decode(payload, token, color);
        if (!data) return false;
        // No fn: cmux's removal is on its way to the host, whose fork then ends this request.
        if (slot.fn == nullptr) return true;
        slot.Opened(token);
        reinterpret_cast<ColorFn>(slot.fn)(slot.context, event, browser, token, color, data->fork());
        return true;
      }
      case cmux_host::choosers::kDevice: {
        const std::unique_ptr<DeviceChooserData> data = DeviceChooserData::Decode(payload, token);
        if (!data) return false;
        if (slot.fn == nullptr) return true;
        slot.Opened(token);
        reinterpret_cast<ChooserFn>(slot.fn)(slot.context, event, browser, token, data->fork());
        return true;
      }
      case cmux_host::choosers::kDesktopMedia: {
        const std::unique_ptr<DesktopMediaData> data = DesktopMediaData::Decode(payload, token);
        if (!data) return false;
        if (slot.fn == nullptr) return true;
        slot.Opened(token);
        reinterpret_cast<ChooserFn>(slot.fn)(slot.context, event, browser, token, data->fork());
        return true;
      }
    }
    return false;
  }

  // Ends `fn`'s open requests of `handler` at `fn`, the open list emptied first (an fn may set handlers again).
  void EndOpen(Handler handler, void* fn, void* context) {
    std::vector<int64_t> open;
    open.swap(slots_[handler].open);
    if (fn == nullptr) return;
    for (int64_t token : open) CallEnd(handler, fn, context, token);
  }

  static void CallEnd(Handler handler, void* fn, void* context, int64_t token) {
    if (fn == nullptr) return;
    const int event = cmux_host::choosers::EndEventOf(handler);
    if (handler == cmux_host::choosers::kColor) {
      reinterpret_cast<ColorFn>(fn)(context, event, 0, token, 0, nullptr);
    } else {
      reinterpret_cast<ChooserFn>(fn)(context, event, 0, token, nullptr);
    }
  }

  bool Send(Handler handler, bool installed) {
    return transport_ != nullptr && transport_->send_installed(transport_->context, handler, installed);
  }

  // Sends installed/removed when it differs from what the host last took; a
  // refused send leaves the difference, so the next set or Attach sends it.
  void Sync(Handler handler) {
    Slot& slot = slots_[handler];
    const bool installed = slot.fn != nullptr;
    if (installed != slot.sent_installed && Send(handler, installed)) slot.sent_installed = installed;
  }

  const Transport* transport_ = nullptr;
  std::array<Slot, kHandlerCount> slots_;
};

// One per loaded dylib, as remote_shim_local.mm's LocalClient: the C ABI has no handle to carry an instance.
Choosers& Instance() {
  static Choosers choosers;
  return choosers;
}

}  // namespace

void Attach(const Transport* transport) {
  AssertMainThread();
  Instance().Attach(transport);
}

void Detach() {
  AssertMainThread();
  Instance().Detach();
}

bool IsHandlerEvent(int kind) { return cmux_host::choosers::HandlerOfEventKind(kind).has_value(); }

bool Deliver(int kind, int browser, int request, int64_t a, int64_t b, std::string_view payload) {
  AssertMainThread();
  return Instance().Deliver(kind, browser, request, a, b, payload);
}

}  // namespace cmux_remote::choosers

extern "C" {

CMUX_SHIM_EXPORT int cmux_shim_set_color_chooser_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, unsigned int color, const void* data),
    void* context) {
  cmux_remote::choosers::AssertMainThread();
  return cmux_remote::choosers::Instance().Set(cmux_host::choosers::kColor, reinterpret_cast<void*>(fn), context);
}

CMUX_SHIM_EXPORT int cmux_shim_set_device_chooser_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, const void* data), void* context) {
  cmux_remote::choosers::AssertMainThread();
  return cmux_remote::choosers::Instance().Set(cmux_host::choosers::kDevice, reinterpret_cast<void*>(fn), context);
}

CMUX_SHIM_EXPORT int cmux_shim_set_desktop_media_handler(
    void (*fn)(void* context, int event, int browser_id, int64_t token, const void* data), void* context) {
  cmux_remote::choosers::AssertMainThread();
  return cmux_remote::choosers::Instance().Set(cmux_host::choosers::kDesktopMedia, reinterpret_cast<void*>(fn),
                                               context);
}

}  // extern "C"

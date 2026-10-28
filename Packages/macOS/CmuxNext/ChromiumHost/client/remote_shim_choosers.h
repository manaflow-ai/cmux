// The remote shim's color chooser, device chooser and screen-share picker
// handlers (wire in ../src/host_choosers.h): the local
// exports cmux_shim_set_color_chooser_handler, _set_device_chooser_handler and
// _set_desktop_media_handler. The client keeps cmux's fn, tells the host only
// whether one is set, and calls it on the main thread with the fork's struct
// rebuilt from each CMUX_SHIM_COLOR_CHOOSER, _DEVICE_CHOOSER and
// _DESKTOP_MEDIA push, as the in-process shim calls it from the fork's
// handler (CEFShim/src/shim_helper_host.mm).
//
// The runtime (remote_shim.mm) calls Attach when a host's HELLO arrives,
// Detach when the host is gone, and Deliver for those event kinds instead of
// the app's event fn. Main thread only; no call waits for the host.
#pragma once

#include <cstdint>
#include <string_view>

#include "host_choosers.h"

namespace cmux_remote::choosers {

// What the runtime sends for these exports. Returns at once; false means
// nothing was sent.
struct Transport {
  void* context;
  // The handler's setter op with i32 installed.
  bool (*send_installed)(void* context, cmux_host::choosers::Handler handler, bool installed);
};

// A host's HELLO arrived: sends go to `transport` (which outlives the matching
// Detach), and each handler cmux has set is installed in that host.
void Attach(const Transport* transport);
// The host is gone and its open requests with it: each one the app has not
// seen end gets its END or CLOSE (browser 0), as when the fork ends a request.
void Detach();

// True for the event kinds Deliver takes.
bool IsHandlerEvent(int kind);
// A push of one of them: calls the handler's fn (false when the payload is not
// host_choosers.h's, a malformed frame). With no fn set it does nothing.
bool Deliver(int kind, int browser, int request, int64_t a, int64_t b, std::string_view payload);

}  // namespace cmux_remote::choosers

// When the Chromium host may take focus or become the active app (browser_host_main.mm). The host never does on its
// own: cmux, the app the person works in, moves a page's focus, in both modes.
//
// Measured on a fleet Mac (in-tree pages approach 4, front-before-2, 2026-11-28, the host's activation probe):
// a page open made its host the person's front app in two ways.
// 1. CEF focuses a page after the first navigation of a new browser (ChromeBrowserHostImpl::Create:
//    OnSetFocus(FOCUS_SOURCE_NAVIGATION)). For a Chrome-style child browser that ends in
//    CefBrowserPlatformDelegateChromeChildWindow::SetFocus -> NativeWidgetMacNSWindowHost::SetVisibilityState ->
//    [NSApp activateIgnoringOtherApps:YES]: 4 of 4 remote pages, and the layer-hosting page. The host's
//    CefFocusHandler cancels every navigation's focus (true from OnSetFocus); cmux's own requests (kFocus ->
//    SetFocus, FOCUS_SOURCE_SYSTEM) keep CEF's path, which focuses the page without activating the host.
// 2. With cmux the active app, macOS activated the host as it finished launching (the process cmux started with
//    posix_spawn; no activation call in the host, about 8 ms after didFinishLaunching). macOS never activates a
//    prohibited app, so the host stays NSApplicationActivationPolicyProhibited until it has finished launching and
//    made its first page, then takes the accessory policy its windows (popups, bubbles) need.
// No CEF or AppKit dependency, so the test compiles it alone (scripts/cmux-next/test-host-focus-policy-cpp.sh);
// browser_host_main.mm checks the values against CEF's and AppKit's own.
#ifndef CMUX_HOST_FOCUS_POLICY_H_
#define CMUX_HOST_FOCUS_POLICY_H_

namespace cmux_host {

// cef_focus_source_t.
constexpr int kFocusSourceNavigation = 0;
constexpr int kFocusSourceSystem = 1;

// NSApplicationActivationPolicy.
constexpr long kActivationPolicyAccessory = 1;
constexpr long kActivationPolicyProhibited = 2;

// True when the host cancels a focus request from `source` (returns true from CefFocusHandler::OnSetFocus).
inline bool CancelsFocus(int source) { return source == kFocusSourceNavigation; }

// The activation policy the host holds: prohibited until it has finished launching and made its first page.
inline long ActivationPolicy(bool finished_launching, bool page_created) {
  return finished_launching && page_created ? kActivationPolicyAccessory : kActivationPolicyProhibited;
}

}  // namespace cmux_host

#endif  // CMUX_HOST_FOCUS_POLICY_H_

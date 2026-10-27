public import AppKit

extension NSTrackingArea.Options {
    /// When a hover tracking area hears the pointer: in every window of the active app, key or
    /// not, and not while another app is active, as AppKit's own controls track. An inactive cmux
    /// then takes no wakeup per mouse move over its windows (plans/cmux-next/chrome-parity/p14-energy.md,
    /// Q5). A `CMUX_NEXT_NO_ACTIVATE=1` launch never activates the app, so its hover tracks always.
    @MainActor public static var activeForHover: NSTrackingArea.Options {
        // wakeup-allow: bounded only CMUX_NEXT_NO_ACTIVATE launches, which never activate the app, track while inactive
        WindowPlacement.noActivate ? .activeAlways : .activeInActiveApp
    }
}

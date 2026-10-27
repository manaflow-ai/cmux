public import AppKit

extension WindowPlacement {
    /// When a hover tracking area is active: while cmux is the active app, so mouse moves over a
    /// window behind another app do not wake cmux (p14-energy section C, Q5). A
    /// `CMUX_NEXT_NO_ACTIVATE` launch is never the active app, so there it tracks always and agent
    /// and capture runs still see hover (as the themed tooltips do).
    public static var hoverActivation: NSTrackingArea.Options {
        // wakeup-allow: debug only in CMUX_NEXT_NO_ACTIVATE agent and capture launches, never in a person's run
        noActivate ? .activeAlways : .activeInActiveApp
    }
}

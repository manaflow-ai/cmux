import AppKit
import CmuxNextDesign

/// Keeps restored windows on screen: the saved frame on today's displays
/// (`WindowPlacement.restoredFrame`, #25568), which also fits a frame saved on
/// a larger display that is gone (lid close) onto the screen that shows it.
enum WindowPlacementFallback {
    static func visible(_ frame: CGRect, display: String?) -> CGRect {
        let screens = NSScreen.screens.map { (id: displayID(of: $0), visible: $0.visibleFrame) }
        return place(frame, display: display, screens: screens)
    }

    /// Pure placement (`WindowPlacement.restoredFrame`): `screens` are (display id, visible frame), main first.
    static func place(_ frame: CGRect, display: String?, screens: [(id: String?, visible: CGRect)]) -> CGRect {
        WindowPlacement.restoredFrame(frame, display: display, screens: screens)
    }

    /// Stable id of the display showing `screen` (survives reconnects).
    static func displayID(of screen: NSScreen) -> String? {
        // SAFETY: CGDisplayCreateUUIDFromDisplayID follows the Create rule (+1), which takeRetainedValue balances.
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = unsafe CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

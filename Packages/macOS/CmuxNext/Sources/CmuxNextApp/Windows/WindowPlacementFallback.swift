import AppKit
import CmuxNextDesign

/// Keeps restored windows on screen: the saved frame on today's displays
/// (`WindowPlacement.restoredFrame`, #25568).
enum WindowPlacementFallback {
    static func visible(_ frame: CGRect, display: String?) -> CGRect {
        let screens = NSScreen.screens.map { (id: displayID(of: $0), visible: $0.visibleFrame) }
        return WindowPlacement.restoredFrame(frame, display: display, screens: screens)
    }

    /// Stable id of the display showing `screen` (survives reconnects).
    static func displayID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

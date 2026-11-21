public import AppKit

/// Keeps restored windows on screen: the saved frame on today's displays
/// (`WindowPlacement.restoredFrame`, #25568).
@MainActor public struct WindowPlacementFallback {
    public init() {}
    public static func visible(_ frame: CGRect, display: String?) -> CGRect {
        let screens = NSScreen.screens.map { (id: displayID(of: $0), visible: $0.visibleFrame) }
        return WindowPlacement.restoredFrame(frame, display: display, screens: screens)
    }

    /// Stable id of the display showing `screen` (survives reconnects).
    public static func displayID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

public import AppKit

extension NSScreen {
    /// The stable id of the display this screen shows (it survives reconnects).
    public var stableDisplayID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Keeps a restored window on screen: its saved `frame` on today's displays (`WindowPlacement.restoredFrame`, #25568).
    public static func visibleRestoredFrame(_ frame: CGRect, display: String?) -> CGRect {
        WindowPlacement.restoredFrame(frame, display: display, screens: screens.map { (id: $0.stableDisplayID, visible: $0.visibleFrame) })
    }
}

import AppKit

/// Keeps restored windows on screen: a saved frame that no connected
/// display shows is centered on its saved display when that is connected,
/// else on the main screen.
enum WindowPlacementFallback {
    static func visible(_ frame: CGRect, display: String?) -> CGRect {
        let screens = NSScreen.screens.map { (id: displayID(of: $0), visible: $0.visibleFrame) }
        return place(frame, display: display, screens: screens)
    }

    /// Pure placement: `screens` are (display id, visible frame), main first.
    static func place(_ frame: CGRect, display: String?, screens: [(id: String?, visible: CGRect)]) -> CGRect {
        // Visible enough to grab: a 40 pt square of the frame on some screen.
        if screens.contains(where: { $0.visible.intersection(frame).width >= 40 && $0.visible.intersection(frame).height >= 40 }) {
            return frame
        }
        guard let target = screens.first(where: { display != nil && $0.id == display }) ?? screens.first else { return frame }
        let size = CGSize(width: min(frame.width, target.visible.width), height: min(frame.height, target.visible.height))
        return CGRect(x: target.visible.midX - size.width / 2, y: target.visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Stable id of the display showing `screen` (survives reconnects).
    static func displayID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

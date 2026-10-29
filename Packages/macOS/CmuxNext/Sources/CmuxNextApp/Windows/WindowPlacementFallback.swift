import AppKit

/// Keeps restored windows on screen: a saved frame that no connected
/// display shows is centered on its saved display when that is connected,
/// else on the main screen. A frame a screen does show fits that screen
/// with its title bar on it: after the lid closes or a display goes, a
/// frame saved on a larger display is shrunk onto the screen that shows
/// most of it (AppKit's `setFrame` does not constrain it).
enum WindowPlacementFallback {
    static func visible(_ frame: CGRect, display: String?) -> CGRect {
        let screens = NSScreen.screens.map { (id: displayID(of: $0), visible: $0.visibleFrame) }
        return place(frame, display: display, screens: screens)
    }

    /// Pure placement: `screens` are (display id, visible frame), main first.
    static func place(_ frame: CGRect, display: String?, screens: [(id: String?, visible: CGRect)]) -> CGRect {
        // Visible enough to grab: a 40 pt square of the frame on some screen. The screen showing most of it
        // decides; the frame keeps its place unless it is larger than that screen or its top is above it.
        let shown = screens.filter { $0.visible.intersection(frame).width >= 40 && $0.visible.intersection(frame).height >= 40 }
        if let home = shown.max(by: { area($0.visible.intersection(frame)) < area($1.visible.intersection(frame)) }) {
            return fitted(frame, in: home.visible)
        }
        guard let target = screens.first(where: { display != nil && $0.id == display }) ?? screens.first else { return frame }
        let size = CGSize(width: min(frame.width, target.visible.width), height: min(frame.height, target.visible.height))
        return CGRect(x: target.visible.midX - size.width / 2, y: target.visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// `frame` at most `screen`'s size, its top (the title bar) not above `screen`'s top; a frame that already
    /// fits and whose top is on the screen is returned as it is (one the person pushed partly off a side or the
    /// bottom stays there).
    private static func fitted(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        guard size != frame.size || frame.maxY > screen.maxY else { return frame }
        let x = size.width == frame.width ? frame.minX : min(max(frame.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// Stable id of the display showing `screen` (survives reconnects).
    static func displayID(of screen: NSScreen) -> String? {
        // SAFETY: CGDisplayCreateUUIDFromDisplayID follows the Create rule (+1), which takeRetainedValue balances.
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = unsafe CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

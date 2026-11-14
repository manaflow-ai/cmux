import AppKit
import CmuxNextDesign

// The titlebar row's accessory (an incognito window's badge) between the
// leading reserve and the + (cmux #37351).
extension SidebarView {
    /// Where the accessory goes in the titlebar row, in the sidebar's coordinates.
    ///
    /// With `room` for its fitting width it takes that, centered on the row's
    /// line. With less it is an icon of the row: a square of the toolbar
    /// buttons' side on the +'s frame line, never a pill stretched to the
    /// leftover width. With no room for that square it is empty (hidden).
    ///
    /// - Parameters:
    ///   - size: The accessory's fitting size (its full width).
    ///   - x: The row's leading x, after the traffic lights and the toolbar band.
    ///   - room: The width between `x` and the controls after it.
    ///   - button: The toolbar buttons' side (the +).
    ///   - buttonY: The +'s minY, so a square accessory lines up with it exactly.
    ///   - rowMidY: The row's center line (the traffic lights').
    static func titlebarAccessoryFrame(fitting size: NSSize, x: CGFloat, room: CGFloat, button: CGFloat,
                                       buttonY: CGFloat, rowMidY: CGFloat) -> NSRect {
        if room >= size.width {
            return NSRect(x: x, y: (rowMidY - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        guard room >= button else { return .zero }
        return NSRect(x: x, y: buttonY, width: button, height: button)
    }
}

extension SidebarViewComponents {
    /// The titlebar row's middle in window coordinates: the top row's shared line (`TopRowLine`), else the
    /// traffic lights' center, else nil (no lights: the row's own middle).
    static func titlebarRowMidY(in window: NSWindow) -> CGFloat? {
        guard let lights = WindowTitlebar.trafficLightsFrame(in: window) else { return nil }
        guard let line = WindowTitlebar.topRowLine(in: window), let content = window.contentView else { return lights.midY }
        return content.convert(CGPoint(x: 0, y: content.bounds.maxY - line.centerY), to: nil).y
    }
}

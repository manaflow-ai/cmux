public import AppKit

/// A window's traffic-light buttons, found once. AppKit asks the window for them each time it
/// rebuilds the titlebar drag regions (`_resetDragMargins`, after a view frame or first-responder
/// change), and its own lookup searches the whole view tree: about 7 ms per tab switch in a
/// 16-pane window (cx-8w027.25). A window subclass answers `standardWindowButton(_:)` from here.
/// A button AppKit replaced (a style or full-screen change) has left the window, so the cache
/// misses and looks again.
@MainActor
public struct StandardWindowButtons {
    private var buttons: [NSWindow.ButtonType: NSButton] = [:]

    public init() {}

    /// The cached `type` button of `window`, while it is still in `window`.
    public func cached(_ type: NSWindow.ButtonType, in window: NSWindow) -> NSButton? {
        guard let button = buttons[type], button.window === window, button.superview != nil else { return nil }
        return button
    }

    /// Keeps `button`, AppKit's answer for `type` (looked up outside any access to this value:
    /// AppKit may ask the window again while it searches).
    public mutating func store(_ button: NSButton?, for type: NSWindow.ButtonType, in window: NSWindow) {
        buttons[type] = button?.window === window ? button : nil
    }
}

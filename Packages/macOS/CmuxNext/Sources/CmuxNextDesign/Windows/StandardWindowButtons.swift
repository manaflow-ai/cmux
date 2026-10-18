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

    /// The cached `type` button of `window`, else `lookup()` (AppKit's search), kept while it is in `window`.
    public mutating func button(_ type: NSWindow.ButtonType, in window: NSWindow, lookup: () -> NSButton?) -> NSButton? {
        if let button = buttons[type], button.window === window, button.superview != nil { return button }
        let button = lookup()
        buttons[type] = button?.window === window ? button : nil
        return button
    }
}

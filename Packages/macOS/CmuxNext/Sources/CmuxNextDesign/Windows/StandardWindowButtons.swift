public import AppKit

/// A window's traffic-light buttons, found once. AppKit asks the window for them each time it
/// rebuilds the titlebar drag regions (`_resetDragMargins`, after a view frame or first-responder
/// change), and its own lookup searches the whole view tree: about 7 ms per tab switch in a
/// 16-pane window (cx-8w027.25). A window subclass answers `standardWindowButton(_:)` from here.
/// A button AppKit replaced (a style or full-screen change) has left the window, so the cache
/// misses and looks again. A type the window does not have is an answer too, kept while the window shape holds.
@MainActor
public struct StandardWindowButtons {
    private var buttons: [NSWindow.ButtonType: NSButton] = [:]
    /// Types AppKit answered with no button, and the window shape that answer holds for.
    private var absent: [NSWindow.ButtonType: Shape] = [:]

    /// What decides which buttons a window has: its style, whether it shows a document, and its frame view (AppKit
    /// replaces that on a style or full-screen change). An absent answer is good while the shape is the same.
    private struct Shape: Equatable {
        let style: NSWindow.StyleMask.RawValue
        let document: Bool
        let frameView: ObjectIdentifier?

        @MainActor init(_ window: NSWindow) {
            style = window.styleMask.rawValue
            document = window.representedURL != nil
            frameView = window.contentView?.superview.map(ObjectIdentifier.init)
        }
    }

    public init() {}

    /// What the cache knows about `type` in `window`: `.unknown` (ask AppKit, then `store`), or AppKit's answer.
    public enum Answer {
        case unknown
        case known(NSButton?)
    }

    /// The cached answer for `type` in `window`. Ask AppKit only on `.unknown`.
    public func answer(_ type: NSWindow.ButtonType, in window: NSWindow) -> Answer {
        if let button = cached(type, in: window) { return .known(button) }
        if let shape = absent[type], shape == Shape(window) { return .known(nil) }
        return .unknown
    }

    /// The cached `type` button of `window`, while it is still in `window`.
    public func cached(_ type: NSWindow.ButtonType, in window: NSWindow) -> NSButton? {
        guard let button = buttons[type], button.window === window, button.superview != nil else { return nil }
        return button
    }

    /// Keeps `button`, AppKit's answer for `type` (looked up outside any access to this value:
    /// AppKit may ask the window again while it searches).
    public mutating func store(_ button: NSButton?, for type: NSWindow.ButtonType, in window: NSWindow) {
        buttons[type] = button?.window === window ? button : nil
        absent[type] = button == nil ? Shape(window) : nil
    }
}

public import AppKit

/// A click on a button of a full-screen window's top band that AppKit's full-screen titlebar window
/// took instead (the person, 2026-11-23: "tapping the Chief > button does nothing").
///
/// While a window is in full screen and the menu bar shows (the pointer touched the screen's top
/// edge, or the menu bar never hides), AppKit slides its titlebar window (`NSToolbarFullScreenWindow`,
/// ``WindowOverlayHost/isAppKitChrome(_:)``) down under the menu bar, over the window's own top
/// band: about 32 points under a 30 point menu bar on the person's display. The window server gives
/// the presses there to that window, so a control of the window under it, Home's name pill (its
/// center 58 points from the top) or the Chats and compose buttons, never saw the click
/// (`cmux app clicks` listed the press under `NSToolbarFullScreenWindow`).
///
/// A left press there that the titlebar window has no control for (its traffic lights keep theirs)
/// and that lands on an enabled button of the window it belongs to goes to that button: the press
/// is held, and its release on the button clicks it (`performClick`, so it highlights and sends
/// its action as a click on it does). Every other press goes on to AppKit as before.
@MainActor
public final class FullScreenTitlebarPress {
    /// The full-screen window whose top band `window` covers: its parent when `window` is AppKit's
    /// full-screen titlebar window of a window in full screen, else nil. A seam for tests (test
    /// windows are never in full screen, and AppKit's class is private).
    public var coveredWindow: (NSWindow) -> NSWindow? = { window in
        guard WindowOverlayHost.isAppKitChrome(window), let parent = window.parent,
              parent.styleMask.contains(.fullScreen) else { return nil }
        return parent
    }

    /// The button the held press is for, and the titlebar window that has it.
    private weak var pressed: NSButton?
    private weak var source: NSWindow?

    public init() {}

    /// Takes `event`, delivered to `window`, when it is a press (or the release of one) this routes
    /// to a button of the covered window. True when it took the event: AppKit must not get it.
    public func take(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        switch event.type {
        case .leftMouseDown:
            pressed = nil
            source = nil
            guard let button = button(under: event, in: window) else { return false }
            pressed = button
            source = window
            return true
        case .leftMouseDragged:
            return source === window && pressed != nil
        case .leftMouseUp:
            guard source === window, let button = pressed else { return false }
            pressed = nil
            source = nil
            if self.button(under: event, in: window) === button { button.performClick(nil) }
            return true
        default:
            return false
        }
    }

    /// The enabled, shown button of the covered window at `event`'s point, when the titlebar window
    /// has no control of its own there.
    private func button(under event: NSEvent, in window: NSWindow) -> NSButton? {
        guard let covered = coveredWindow(window), Self.control(at: event.locationInWindow, in: window) == nil else { return nil }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let point = covered.convertPoint(fromScreen: screen)
        guard let button = Self.control(at: point, in: covered) as? NSButton, button.isEnabled,
              !button.isHiddenOrHasHiddenAncestor else { return nil }
        return button
    }

    /// The control under `point` (window coordinates) in `window`: the hit view or its nearest
    /// control ancestor.
    private static func control(at point: NSPoint, in window: NSWindow) -> NSControl? {
        guard let frame = window.contentView?.superview ?? window.contentView else { return nil }
        var view = frame.hitTest(frame.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if let control = current as? NSControl { return control }
            view = current.superview
        }
        return nil
    }
}

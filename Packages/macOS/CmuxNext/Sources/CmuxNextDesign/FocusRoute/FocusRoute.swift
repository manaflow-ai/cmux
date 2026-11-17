public import AppKit

/// The one way cmux code moves the keyboard (plans/cmux-next/focus-loss-AUDIT.md, "Focus route").
///
/// Every first responder move, key window change and app activation names its caller and its
/// reason here, so the focus log and `cmux app call debug.focus_log` say who moved the keys and
/// why, and the window's gate can refuse a move the person did not start. A window that judges
/// moves (``FocusRouting``, the app's main window) gets the route with the call; any other window
/// gets a plain AppKit call. A move that does not come through here still works, and the log calls it
/// `unrouted`; `scripts/cmux-next/check-focus-routes.py` refuses a new one at push.
///
/// ```swift
/// FocusRoute(.system, "a new agent tab's composer").moveKeyboard(in: window, to: composer)
/// FocusRoute(.person, "the address bar's Escape").moveKeyboard(in: window, to: webView)
/// ```
public struct FocusRoute: Sendable, Hashable, CustomStringConvertible {
    /// Who started the move.
    public enum Origin: String, Sendable, Hashable {
        /// A key, click or command of the person (also one that lands later, after an async step).
        case person
        /// The app by itself: a daemon delta, a timer, a mount, a page's own request. Refused while
        /// the person types into another text input (``ResponderMoveGate``).
        case system
    }

    /// Who started the move.
    public let origin: Origin
    /// Why the keys move, in a few words.
    public let reason: String
    /// The caller, `Module/File.swift:line`.
    public let caller: String

    /// - Parameters:
    ///   - origin: Who started the move.
    ///   - reason: Why, in a few words (the focus log shows it).
    ///   - file: The caller's file (filled in by the compiler).
    ///   - line: The caller's line (filled in by the compiler).
    public init(_ origin: Origin, _ reason: String, file: StaticString = #fileID, line: UInt = #line) {
        self.origin = origin
        self.reason = reason
        caller = "\(file):\(line)"
    }

    public var description: String { "\(origin.rawValue) \(caller) \(reason)" }

    /// Makes `responder` the first responder of `window` through this route; false when the window
    /// refused it.
    @MainActor @discardableResult
    public func moveKeyboard(in window: NSWindow?, to responder: NSResponder?) -> Bool {
        guard let window else { return false }
        if let routed = window as? any FocusRouting { return routed.makeFirstResponder(responder, through: self) }
        // focus-route: the route itself, for a window that does not judge moves
        return window.makeFirstResponder(responder)
    }

    /// Makes `window` the key window through this route (`orderFront` too when `front`).
    @MainActor
    public func makeKey(_ window: NSWindow?, front: Bool = false) {
        guard let window else { return }
        if let routed = window as? any FocusRouting { return routed.makeKey(through: self, front: front) }
        // focus-route: the route itself, for a window that does not judge moves
        if front { window.makeKeyAndOrderFront(nil) } else { window.makeKey() }
    }

    /// Activates the app through this route.
    @MainActor
    public func activateApp() {
        // focus-route: the route itself
        NSApp.activate()
    }
}

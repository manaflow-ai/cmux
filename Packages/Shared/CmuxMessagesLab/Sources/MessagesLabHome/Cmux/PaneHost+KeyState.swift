import AppKit

extension ChatController {
    /// The window view's inactive state for one window key state: inactive only when the pane follows its window's
    /// key state (MessagesLab's Messages parity, `--follow-key-state`) and that window is not key. cmux keeps the key
    /// look otherwise (Lawrence 2026-10-18: "imessage home ui should not have different appearance when imessage tab
    /// is not focused"): in cmux Home sits beside terminals and other windows, and a switch read as Home breaking.
    static func viewInactive(followsKeyWindow: Bool, windowIsKey: Bool) -> Bool {
        followsKeyWindow && !windowIsKey
    }

    /// cmux (cx-95476, MessagesLab 806ef0c inactive-per-view): this pane's window view follows its own window only:
    /// didBecomeKey -> active, didResignKey -> inactive (an app that deactivates resigns its key window),
    /// `!window.isKeyWindow` when it joins a window, each through `viewInactive`. No other pane changes; a display
    /// move never sets it. Without `followsKeyWindow` the view stays active.
    /// The field's resting hairline follows the same key state in either mode (cmux#39302): the system glass loses
    /// its lit rim in a window that is not key.
    func followKeyState() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window, let demo else { return }
        // Test modes (noFocus): the state the arguments name, no key observers.
        if Self.noFocus {
            demo.setInactive(!Self.args.contains("--active"))
            refreshFieldEdge()
            return
        }
        let follows = followsKeyWindow
        keyStateChanged(windowIsKey: window.isKeyWindow, follows: follows)
        keyObservers = [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)].map { name, key in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.keyStateChanged(windowIsKey: key, follows: follows)
            }
        }
    }

    /// One key state of this pane's own window: the field's hairline, and the window view's inactive look when the
    /// pane follows key state.
    func keyStateChanged(windowIsKey: Bool, follows: Bool) {
        if let fieldEdgeTheme { host.fieldChrome.applyEdge(fieldEdgeTheme, windowIsKey: windowIsKey) }
        demo?.setInactive(Self.viewInactive(followsKeyWindow: follows, windowIsKey: windowIsKey))
    }

    /// The window's key state the field draws for: a test mode's is the state its arguments name.
    var fieldWindowIsKey: Bool { Self.noFocus ? Self.args.contains("--active") : (host.window?.isKeyWindow ?? false) }

    /// A theme change: the field's glass, symbols and hairline, kept for the next key change.
    func applyFieldTheme(light: Bool, symbol: NSColor, edge: NSColor?, restingEdge: NSColor?) {
        fieldEdgeTheme = FieldEdgeTheme(light: light, edge: edge, restingEdge: restingEdge)
        host.fieldChrome.applyTheme(light: light, symbol: symbol, edge: edge, restingEdge: restingEdge, windowIsKey: fieldWindowIsKey)
    }

    /// The field's hairline for the current key state (a theme already applied).
    func refreshFieldEdge() {
        if let fieldEdgeTheme { host.fieldChrome.applyEdge(fieldEdgeTheme, windowIsKey: fieldWindowIsKey) }
    }
}

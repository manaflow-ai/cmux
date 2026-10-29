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
    /// move never sets it. Without `followsKeyWindow` the view stays active. The same observers tell the compose bar's
    /// controls (their Full Keyboard Access ring shows only in the key window).
    func followKeyState() {
        keyObservers = []
        guard let window, let demo else { return }
        // Test modes (noFocus): the state the arguments name; the window's key state does not change it.
        let follows = followsKeyWindow && !Self.noFocus
        if Self.noFocus {
            demo.setInactive(!Self.args.contains("--active"))
        } else {
            demo.setInactive(Self.viewInactive(followsKeyWindow: follows, windowIsKey: window.isKeyWindow))
        }
        keyObservers = [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)].map { name, key in
            MainQueueObservation(name, object: window) { [weak self] _ in
                guard let self else { return }
                if follows { self.demo?.setInactive(Self.viewInactive(followsKeyWindow: follows, windowIsKey: key)) }
                self.host.composeChrome.windowKeyChanged(isKey: key)
            }
        }
    }
}

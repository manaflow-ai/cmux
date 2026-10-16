import AppKit

extension ChatController {
    /// cmux (cx-95476, MessagesLab 806ef0c inactive-per-view): this pane's window view follows its own window's key
    /// state only: didBecomeKey -> active, didResignKey -> inactive (an app that deactivates resigns its key window),
    /// `!window.isKeyWindow` when it joins a window. No other pane changes; a display move never sets it.
    func followKeyState() {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window, let demo, !Self.noFocus else { return }
        demo.setInactive(!window.isKeyWindow)
        keyObservers = [(NSWindow.didBecomeKeyNotification, false), (NSWindow.didResignKeyNotification, true)].map { name, inactive in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.demo?.setInactive(inactive) }
        }
    }
}

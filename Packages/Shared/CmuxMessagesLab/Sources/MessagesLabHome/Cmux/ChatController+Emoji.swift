// cmux: the emoji button beside the message box. Not a vendored file.
import AppKit

extension ChatController {
    /// Opens the system emoji picker for the message box.
    ///
    /// The picker attaches to the key window's current text input context,
    /// and AppKit switches that context to a new first responder only after
    /// the event that moved the keyboard has been handled. The button used to
    /// focus the field and ask for the picker in the same click: unless the
    /// field already held the keyboard, the picker opened for the old
    /// responder (the pane or the transcript), so nothing showed or a chosen
    /// emoji went nowhere. Now the field takes the keyboard (its caret stays
    /// where it was) and its window is brought forward; the picker is asked
    /// one turn later, or once the window is key when activation takes longer.
    /// A field that cannot take the keyboard still gets the picker asked, as
    /// before.
    func showEmojiPicker() {
        guard let window, let field = demo?.compose.textView.view else { openEmojiPalette(); return }
        if window.isKeyWindow, window.firstResponder === field { openEmojiPalette(); return }
        if !Self.noFocus {
            if !window.isKeyWindow { bringWindowForward(window) }
            window.makeFirstResponder(field)
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            if window.isKeyWindow || !window.isVisible || NSApp.isActive { self.openEmojiPalette(); return }
            // The app is still activating: ask once the window is key (one ask, then the observer goes).
            let once = OneShotObserver()
            once.token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, once] _ in
                Task { @MainActor in
                    guard once.token != nil else { return }
                    once.remove()
                    self?.openEmojiPalette()
                }
            }
        }
    }
}

/// A notification observer that removes itself after its first delivery.
@MainActor private final class OneShotObserver {
    var token: NSObjectProtocol?
    func remove() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

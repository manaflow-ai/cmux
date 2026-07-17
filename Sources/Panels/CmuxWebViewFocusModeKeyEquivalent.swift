import AppKit

@MainActor
extension CmuxWebView {
    /// Focus-mode disposition of a key equivalent: nil when browser focus mode
    /// is not driving this event, otherwise whether it was handled.
    func performBrowserFocusModeKeyEquivalent(
        with event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> Bool? {
        guard let decision = AppDelegate.shared?.handleBrowserFocusModeKeyEvent(
            event,
            webView: self,
            source: "web.performKeyEquivalent"
        ), decision != .inactive else {
            return nil
        }
        switch decision {
        case .inactive:
            return nil
        case .consume:
            return true
        case .forwardToWebView:
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if (normalizedFlags.isEmpty && event.keyCode == 53) ||
                (isReturnKey && !normalizedFlags.contains(.command)) {
                forwardKeyDownToWebKit(event)
                return true
            }
            // Extension manifest commands (e.g. Bitwarden's ⌘⇧L autofill) are
            // browser-chrome shortcuts, so they outrank page content the same
            // way they do in Safari. Focus mode suspends configured cmux
            // shortcuts, which is exactly when a binding like the default ⌘⇧L
            // Open Browser frees the stroke for the extension.
            if AppDelegate.shared?.performBrowserWebExtensionCommandKeyEquivalent(event) == true {
                return true
            }
            let result = super.performKeyEquivalent(with: event)
            // While focus mode is active, the page gets the shortcut once and
            // cmux/main-menu fallback must not see unhandled command equivalents.
            return result || normalizedFlags.contains(.command)
        }
    }
}

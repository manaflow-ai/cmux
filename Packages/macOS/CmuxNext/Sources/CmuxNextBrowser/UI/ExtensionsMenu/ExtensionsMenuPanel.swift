import AppKit
import CmuxNextDesign

/// The Extensions bubble's window: a popup of the shared native host (``NativePopupHost``), a
/// borderless child panel of the browser window, so it draws above Chromium page windows and
/// moves with the window. It takes the keys for the arrow keys and Escape (only while the app is
/// active); the host closes it when it loses them, on a click outside, and when the app or the
/// window goes away.
final class ExtensionsMenuPanel: NativePopupPanel {
    var onKey: ((NSEvent) -> Bool)?

    init() {
        super.init(identifier: ExtensionsMenu.menuIdentifier)
        // Chrome leaves the bubble's window title empty, so VoiceOver does not say "Extensions"
        // twice (crrev.com/c/2661700); the title row says it.
        setAccessibilityLabel(Strings.extensions)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

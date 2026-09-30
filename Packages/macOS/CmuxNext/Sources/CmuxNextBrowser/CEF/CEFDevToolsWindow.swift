import AppKit
import CmuxNextDesign

/// The window of a Chromium tab's DevTools when it is not docked. It holds
/// the same `CEFHostView` the docked DevTools uses, so moving between a
/// dock side and this window only reparents that view: the Chromium
/// DevTools child window follows it (fork parent-view tracking) and keeps
/// its frontend state (console, selection, open panel). Before, a move into
/// or out of a window closed DevTools and opened a new one in Chromium's own
/// top-level window.
///
/// A panel, not a cmux window: it never joins cmux's window list, layout or
/// session, and it closes with its page.
final class CEFDevToolsWindow: NSPanel {
    /// The title bar's close button: the tab closes DevTools.
    var onClose: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 360, height: 240)
        contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        contentView?.wantsLayer = true
        setAccessibilityIdentifier("browser.devtools.window")
        ThemeStore.shared.adopt(self)
        // The initializer places the rect relative to the main screen; set
        // the global frame so the window opens over the cmux window's screen.
        setFrame(frame, display: false)
    }

    /// Puts `host` in the window, filling it.
    func adopt(_ host: NSView) {
        guard let contentView else { return }
        host.removeFromSuperview()
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
    }

    override func performClose(_ sender: Any?) {
        onClose?()
    }

    /// Where the window opens: over the cmux window, inset (AppKit screen
    /// coordinates), or a default size on the main screen.
    static func frame(near window: NSWindow?) -> CGRect {
        if let window {
            let frame = window.frame.insetBy(dx: 40, dy: 40)
            if frame.width >= 400, frame.height >= 300 { return frame }
        }
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGRect(x: screen.midX - 450, y: screen.midY - 300, width: 900, height: 600)
    }
}

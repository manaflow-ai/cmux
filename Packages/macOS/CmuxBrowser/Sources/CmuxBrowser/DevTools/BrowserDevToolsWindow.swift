public import AppKit

/// The window of a page's DevTools while they are not docked. It holds the same host view the
/// docked DevTools use, so moving between a dock side and this window only reparents that view
/// and the engine's DevTools keep their state.
///
/// A panel, not a cmux window: it never joins cmux's window list, layout or session, it does not
/// hide when cmux deactivates, and it closes with its page.
public final class BrowserDevToolsWindow: NSPanel, BrowserDevToolsWindowHosting {
    /// Called when the user closes the window.
    public var onClose: (() -> Void)?

    /// Creates a window over `owner` (inset), or centered on the main screen.
    /// - Parameter owner: The cmux window the page shows in.
    public convenience init(near owner: NSWindow?) {
        self.init(contentRect: Self.frame(near: owner))
    }

    private init(contentRect frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 360, height: 240)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        contentView = content
        setAccessibilityIdentifier("browser.devtools.window")
        // The initializer places the rect relative to the main screen; set the global frame so
        // the window opens over the cmux window's screen.
        setFrame(frame, display: false)
    }

    /// The window title for a page title, as Chrome titles undocked DevTools.
    /// - Parameter pageTitle: The inspected page's title; empty gives a plain title.
    /// - Returns: The title.
    public static func title(forPage pageTitle: String) -> String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "browser.devTools.windowTitlePlain", defaultValue: "Developer Tools", bundle: .module)
        }
        let format = String(localized: "browser.devTools.windowTitle", defaultValue: "Developer Tools – %@", bundle: .module)
        return String(format: format, trimmed)
    }

    public func adopt(_ view: NSView) {
        guard let content = contentView else { return }
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    public func show() {
        orderFront(nil)
    }

    public func dismiss() {
        onClose = nil
        orderOut(nil)
    }

    public func contains(_ window: NSWindow) -> Bool {
        window === self || window.parent === self
    }

    override public func performClose(_ sender: Any?) {
        onClose?()
    }

    /// Where the window opens: over the cmux window inset by 40 points (AppKit screen
    /// coordinates), or 900 x 600 centered on the main screen.
    /// - Parameter window: The cmux window.
    /// - Returns: The frame.
    public static func frame(near window: NSWindow?) -> CGRect {
        if let window {
            let frame = window.frame.insetBy(dx: 40, dy: 40)
            if frame.width >= 400, frame.height >= 300 { return frame }
        }
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGRect(x: screen.midX - 450, y: screen.midY - 300, width: 900, height: 600)
    }
}

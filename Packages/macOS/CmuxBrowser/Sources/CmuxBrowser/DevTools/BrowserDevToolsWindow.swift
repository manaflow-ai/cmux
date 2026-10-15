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
    /// Called when the user moved or resized the window.
    public var onFrameChange: ((CGRect) -> Void)?
    private var frameObservers: [any NSObjectProtocol] = []

    /// Creates a window beside `owner` (``BrowserDevToolsWindowPlacement``), or at `remembered`.
    /// - Parameters:
    ///   - owner: The cmux window the page shows in.
    ///   - remembered: The frame the user last left the window at.
    public convenience init(near owner: NSWindow?, remembered: CGRect? = nil) {
        self.init(contentRect: Self.frame(near: owner, remembered: remembered))
        // Moves, the end of a live resize, and resizes outside one (Zoom, a title bar double click).
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
            let isResize = name == NSWindow.didResizeNotification
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    guard let self else { return }
                    if isResize, self.inLiveResize { return }
                    self.onFrameChange?(self.frame)
                }
            })
        }
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
        onFrameChange = nil
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers = []
        orderOut(nil)
    }

    public func contains(_ window: NSWindow) -> Bool {
        window === self || window.parent === self
    }

    override public func performClose(_ sender: Any?) {
        onClose?()
    }

    /// Where the window opens (AppKit screen coordinates): the remembered frame, else beside the
    /// cmux window so it doesn't cover the page it inspects (``BrowserDevToolsWindowPlacement``).
    /// - Parameters:
    ///   - window: The cmux window.
    ///   - remembered: The frame the user last left the window at.
    /// - Returns: The frame.
    public static func frame(near window: NSWindow?, remembered: CGRect? = nil) -> CGRect {
        let ownerVisible = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        // A remembered frame stays on the screen it was left on, not the cmux window's.
        let visible = remembered.flatMap(Self.visibleFrame(mostOverlapping:)) ?? ownerVisible
        return BrowserDevToolsWindowPlacement().frame(owner: window?.frame, visible: visible, remembered: remembered)
    }

    private static func visibleFrame(mostOverlapping rect: CGRect) -> CGRect? {
        let overlaps = NSScreen.screens.map { screen -> (CGRect, CGFloat) in
            let overlap = screen.frame.intersection(rect)
            return (screen.visibleFrame, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

public import AppKit

/// Where the spare parks: the key main window, following it as it changes.
extension PageHostPool {
    /// Parks the spare in `window`: moves it there (a reparent, no reload), or builds one at the
    /// next idle moment.
    public func follow(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        if let spare, let content = window.contentView { park(spare, in: content) }
        scheduleBuild()
    }

    /// Follows the key main window (`isMainWindow` tells the app's main windows from panels and
    /// popovers); when the target closes, the spare moves to `fallback()` or is dropped.
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?) {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            // crash-allow: queue .main delivers the notification on the main thread.
            MainActor.assumeIsolated {
                guard let self, let window, isMainWindow(window) else { return }
                self.follow(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            // crash-allow: queue .main delivers the notification on the main thread.
            MainActor.assumeIsolated {
                guard let self, let window, window === self.target else { return }
                if let next = fallback(window) { self.follow(next) } else { self.dropSpare(); self.target = nil }
            }
        })
    }

    /// Parks `host` in `content`'s parking view: at the prepared page's size when one is known (the
    /// claim's frame), else filling the window.
    func park(_ host: PageWebView, in content: NSView) {
        if parking.superview !== content {
            parking.frame = content.bounds
            parking.autoresizingMask = [.width, .height]
            content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        if let size = likely?.size {
            host.autoresizingMask = []
            host.frame = CGRect(origin: .zero, size: size)
        } else {
            host.frame = parking.bounds
            host.autoresizingMask = [.width, .height]
        }
        if host.superview !== parking { parking.addSubview(host) }
    }
}

/// Where the spare waits: in the target window (WebKit renders only views in a window and not
/// hidden), fully transparent, never hit by the mouse, out of the accessibility tree (the
/// parking of the new tab spare, NewTabSparePool). A claim reparents the host out of it.
final class PageHostParking: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
}

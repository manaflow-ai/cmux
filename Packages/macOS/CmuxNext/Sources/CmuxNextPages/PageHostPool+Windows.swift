public import AppKit

extension PageHostPool {
    /// Moves the parked spare to the target window without reloading it.
    public func follow(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        if let spare, let content = window.contentView { park(spare, in: content) }
        scheduleBuild()
    }

    /// Follows main windows as they become key and drops the spare after the last one closes.
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?) {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                guard let self, isMainWindow(window) else { return }
                self.follow(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                guard let self, window === self.target else { return }
                if let next = fallback(window) { self.follow(next) }
                else { self.dropSpare(); self.target = nil }
            }
        })
    }

    func park(_ host: PageWebView, in content: NSView) {
        if parking.superview !== content {
            parking.frame = content.bounds
            parking.autoresizingMask = [.width, .height]
            content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        if host.window?.firstResponder === host.webKitView { host.window?.makeFirstResponder(nil) }
        host.frame = parking.bounds
        host.autoresizingMask = [.width, .height]
        if host.superview !== parking { parking.addSubview(host) }
    }
}

/// The spare's parking view is transparent, inaccessible and never hit-testable.
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

public import AppKit
import CmuxNextCompat

extension PageHostPool {
    /// Moves the parked spare to the target window without reloading it.
    public func follow(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        if let spare, let content = window.contentView { park(spare, in: content) }
        scheduleBuild()
    }

    /// A main window showed (its first workspace content): the spare parks there when the pool has
    /// no window on screen yet. A window that never becomes key (an app launched in the background)
    /// otherwise left the pool without a target, and the first Settings open loaded cold.
    public func windowDidAppear(_ window: NSWindow?) {
        guard let window, target?.isVisible != true else { return }
        follow(window)
    }

    /// Follows main windows as they become key and drops the spare after the last one closes.
    /// A main window already on screen (the key one first) is the first target. Also follows the
    /// pooled pages' engine: the app's hosting reads `browser.defaultEngine` from the observable
    /// settings snapshot, so a switch to Chromium drops the spare at once
    /// (``engineMayHaveChanged()``).
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?) {
        guard windowObservers.isEmpty else { return }
        engineObservation = Task { [weak self] in
            var previous: Bool?
            for await serves in ObservationStream({ [weak self] in self?.servesWebKitPage ?? false }) {
                guard let self else { return }
                if let previous, previous != serves { self.engineMayHaveChanged() }
                previous = serves
            }
        }
        let app = NSApplication.shared
        if let shown = app.keyWindow.flatMap({ isMainWindow($0) ? $0 : nil })
            ?? app.windows.first(where: { $0.isVisible && isMainWindow($0) }) {
            follow(shown)
        }
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

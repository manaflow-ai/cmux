public import AppKit
import CmuxNextCompat
public import CmuxNextWakeups

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
    /// A main window already on screen (the key one first) is the first target.
    ///
    /// The notices are read in AppKit's turn and the move runs later as background work on
    /// `mainWork`: re-parking a spare nobody sees never shares the turn of the click or the key that
    /// changed windows (Chrome's best-effort UI-thread queue, kBestEffort in
    /// content/browser/scheduler/browser_task_queues.h). `center` is where the windows post (tests pass their own).
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?,
                      mainWork: MainWorkScheduler, center: NotificationCenter = .default) {
        guard windowObservers.isEmpty else { return }
        let app = NSApplication.shared
        if let shown = app.keyWindow.flatMap({ isMainWindow($0) ? $0 : nil })
            ?? app.windows.first(where: { $0.isVisible && isMainWindow($0) }) {
            follow(shown)
        }
        let noteWindow: @MainActor (Notification) -> NSWindow? = { $0.object as? NSWindow }
        // raw-observer-allow: the follow needs the window that became key, the notice's sender; an AppEvents call carries no sender
        windowObservers.append(MainActorObservation(NSWindow.didBecomeKeyNotification, center: center, read: noteWindow) { [weak self] window in
            guard let window, self != nil else { return }
            // node-free: the pool serves every window; its spare is never shown.
            mainWork.post(.background, owner: "PageHostPool.followKey") { [weak self] in
                guard let self, isMainWindow(window) else { return }
                self.follow(window)
            }
        })
        // raw-observer-allow: the drop needs the closing window, the notice's sender, to compare with the target; an AppEvents call carries no sender
        windowObservers.append(MainActorObservation(NSWindow.willCloseNotification, center: center, read: noteWindow) { [weak self] window in
            guard let window, self != nil else { return }
            // node-free: the pool serves every window; its spare is never shown.
            mainWork.post(.background, owner: "PageHostPool.windowClosed") { [weak self] in
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
        if let view = host.webKitPieces?.view, host.window?.firstResponder === view { host.window?.makeFirstResponder(nil) }
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

    #if DEBUG || CMUX_BENCH_HOOKS
    // `debug.webui`: a parked spare is hidden to the person, whatever its engine was told.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        PageWebView.noteCensusParked(true, in: subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        PageWebView.noteCensusParked(false, in: subview)
    }
    #endif
}

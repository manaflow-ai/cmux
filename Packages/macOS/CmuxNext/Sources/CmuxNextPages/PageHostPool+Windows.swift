public import AppKit

extension PageHostPool {
    /// Moves the parked spare to the target window without reloading it.
    public func follow(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        // No spare while a projection is open (``projectionIsOpen``): parked there it would load the worktree.
        if projectionIsOpen() { dropSpare() }
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
    public func start(isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
                      fallback: @escaping @MainActor (NSWindow) -> NSWindow?) {
        guard windowObservers.isEmpty else { return }
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
        watchCommandKey()
        #if DEBUG || CMUX_BENCH_HOOKS
        // The page spare bench's before arm (scripts/cmux-next/page-spare-bench.py): the spare made at launch and kept.
        if ProcessInfo.processInfo.environment["CMUX_NEXT_BENCH_PAGE_SPARE_AT_LAUNCH"] == "1" { idleLimit = nil; noteLikely() }
        #endif
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

    /// ⌘ pressed alone is a sign of intent (``noteIntent()``): Cmd-, opens Settings in the same key-down as its `,`,
    /// so the press of ⌘ before it is the earliest moment its spare can start. ⌘ with another modifier is not.
    func watchCommandKey() {
        guard commandMonitor == nil else { return }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command { self?.noteIntent() }
            return event
        }
    }

    /// Whether page `id` shows painted in a window: on screen, not the parked spare (`debug.page_open_bench`).
    public func isPageShown(_ id: String) -> Bool {
        NSApp.windows.contains { window in
            guard window.isVisible, let content = window.contentView else { return false }
            return Self.shownPage(id, in: content)
        }
    }

    private static func shownPage(_ id: String, in view: NSView) -> Bool {
        if view is PageHostParking || view.isHidden || view.alphaValue < 0.99 { return false }
        if let page = view as? PageWebView, page.pageID == id { return page.hasPainted && !page.bounds.isEmpty }
        return view.subviews.contains { shownPage(id, in: $0) }
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

import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextWakeups

/// One window's spare, as a pure slot (property-tested): at most one spare,
/// handed out once; only an empty slot asks for a new one.
nonisolated struct NewTabSpareSlot<Spare> {
    private var spare: Spare?

    var shouldWarm: Bool { spare == nil }
    var count: Int { spare == nil ? 0 : 1 }

    /// Callers park only when ``shouldWarm``; a second spare is refused.
    mutating func parked(_ value: Spare) {
        guard spare == nil else { return }
        spare = value
    }

    mutating func take() -> Spare? {
        defer { spare = nil }
        return spare
    }

    mutating func drop() -> Spare? { take() }
}

/// Instant new tab (plans/cmux-next/new-tab.md section 2): one prewarmed new
/// tab page per window, loaded, rendered and connected to acpmux, parked in
/// the window out of sight. Opening the new tab page adopts it in the same
/// main-actor turn (no load, no React mount on the open path); the next
/// spare starts once input has been quiet for ``idleInput``, so making a web
/// view never lands in the user's typing. Memory pressure drops every spare.
/// Spares exist only while the new tab page is likely: Cmd-T opens it
/// (`tabs.newTabKind` page) or it was opened in this session.
@MainActor
final class NewTabSparePool {
    /// One adoption, for `debug.new_tab` (timing test, section 2.3).
    struct Opening {
        var spare: Bool
        /// Main-thread time from the open action to the page in its pane.
        var milliseconds: Double
    }

    static let idleInput: Duration = .milliseconds(750)
    static let maximumOpenings = 64

    private unowned let services: AppServices
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let warmTimer = DemandTimer(owner: "NewTabSparePool.warm")
    private var inputMonitor: Any?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var usedThisSession = false
    private var windowObservers: [any NSObjectProtocol] = []
    private(set) var openings: [Opening] = []

    private final class Entry {
        weak var window: NSWindow?
        var slot = NewTabSpareSlot<AgentPaneView>()
        let parking = NewTabSpareParking()
        init(window: NSWindow) { self.window = window }
    }

    init(services: AppServices) {
        self.services = services
    }

    /// The new tab page is likely soon: spares are worth their memory.
    var isLikely: Bool { usedThisSession || services.settings?.snapshot.newTabKind == .page }

    /// At launch: every main window that becomes key gets a spare while the
    /// page is likely.
    func start() {
        observeWindows()
        for window in services.windows.controllers.compactMap(\.window) where window.isVisible { attach(window) }
    }

    /// A main window: park a spare in it at the next quiet moment.
    func attach(_ window: NSWindow) {
        guard entries[ObjectIdentifier(window)] == nil else { return }
        entries[ObjectIdentifier(window)] = Entry(window: window)
        scheduleWarm()
    }

    /// Once the page was used, every main window that becomes key gets a
    /// spare, and a closing window drops its own (window notifications, no
    /// scan).
    private func observeWindows() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window,
                      self.services.windows.controllers.contains(where: { $0.window === window }) else { return }
                self.attach(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { self?.detach(window) }
            }
        })
    }

    /// A window closed: its spare goes with it.
    func detach(_ window: NSWindow) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        discard(entry.slot.drop())
        entry.parking.removeFromSuperview()
    }

    /// The spare of `window` for a new tab page, or nil (the page loads cold).
    /// The caller adopts it at once; a new spare follows when input is quiet.
    func take(for window: NSWindow?) -> AgentPaneView? {
        usedThisSession = true
        observeWindows()
        guard let window else { return nil }
        guard let entry = entries[ObjectIdentifier(window)] else {
            attach(window)
            return nil
        }
        defer { scheduleWarm() }
        return entry.slot.take()
    }

    func record(_ opening: Opening) {
        openings.append(opening)
        if openings.count > Self.maximumOpenings { openings.removeFirst(openings.count - Self.maximumOpenings) }
    }

    /// Every spare, for `debug.new_tab`: the window number and its page's view.
    var spares: [(window: Int, view: AgentPaneView)] {
        entries.values.compactMap { entry in
            guard let window = entry.window, let view = entry.parking.subviews.first as? AgentPaneView else { return nil }
            return (window.windowNumber, view)
        }
    }

    /// Drops every spare (memory pressure, a new page source).
    func dropAll() {
        for entry in entries.values { discard(entry.slot.drop()) }
    }

    private func discard(_ view: AgentPaneView?) {
        guard let view else { return }
        view.removeFromSuperview()
        view.close()
    }

    // MARK: Warming

    /// Arms the quiet-input deadline; each key or click pushes it back.
    private func scheduleWarm() {
        guard isLikely, services.agentTabs.canHostChat, entries.values.contains(where: { $0.slot.shouldWarm }) else { return }
        watchMemoryPressure()
        if inputMonitor == nil {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
                [weak self] event in
                self?.armWarmTimer()
                return event
            }
        }
        armWarmTimer()
    }

    private func armWarmTimer() {
        warmTimer.schedule(after: Self.idleInput) { @MainActor [weak self] in self?.warmNow() }
    }

    private func warmNow() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        guard isLikely else { return }
        let page = NewTabPage.sparePage(services)
        for entry in entries.values where entry.slot.shouldWarm {
            guard let window = entry.window, let content = window.contentView,
                  let view = services.agentTabs.makeSpare(page) else { continue }
            if entry.parking.superview !== content {
                entry.parking.frame = content.bounds
                entry.parking.autoresizingMask = [.width, .height]
                content.addSubview(entry.parking, positioned: .below, relativeTo: nil)
            }
            view.frame = entry.parking.bounds
            view.autoresizingMask = [.width, .height]
            entry.parking.addSubview(view)
            entry.slot.parked(view)
        }
    }

    private func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.dropAll() }
        }
        source.resume()
        memoryPressure = source
    }
}

/// Where a window's spare waits: in the window (WebKit renders only views in
/// a window and not hidden), fully transparent, never hit by the mouse, and
/// out of the accessibility tree. Adopting the spare reparents it into a pane.
final class NewTabSpareParking: NSView {
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

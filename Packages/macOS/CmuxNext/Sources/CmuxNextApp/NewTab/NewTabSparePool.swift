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

    /// The spare, left in the slot.
    var peek: Spare? { spare }
}

/// Instant new tab (plans/cmux-next/new-tab.md section 2): ONE prewarmed new
/// tab page per app (Lawrence: "a pool of 1"), loaded, rendered and connected
/// to acpmux, parked out of sight in the key main window. When another main
/// window becomes key the parked page moves there (a reparent, no reload).
/// Opening the new tab page in any window adopts it in the same main-actor
/// turn (no load, no React mount on the open path); the next spare starts
/// once input has been quiet for ``idleInput``, so making a web view never
/// lands in the user's typing. Memory pressure drops the spare. A spare
/// exists only while the new tab page is likely: Cmd-T opens it
/// (`tabs.newTabKind` page) or it was opened in this session.
@MainActor
final class NewTabSparePool {
    /// One adoption, for `debug.new_tab` (timing test, section 2.3).
    struct Opening {
        var spare: Bool
        /// The spare was parked in another window than the one it opened in.
        var crossWindow: Bool
        /// Main-thread time from the open action to the page in its pane.
        var milliseconds: Double
    }

    static let idleInput: Duration = .milliseconds(750)
    static let maximumOpenings = 64

    private unowned let services: AppServices
    private var slot = NewTabSpareSlot<AgentPaneView>()
    private let parking = NewTabSpareParking()
    /// The main window the spare parks in (the key one, or the last key one).
    private(set) weak var target: NSWindow?
    private let warmTimer = DemandTimer(owner: "NewTabSparePool.warm")
    private var inputMonitor: Any?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    private var usedThisSession = false
    private var windowObservers: [any NSObjectProtocol] = []
    private(set) var openings: [Opening] = []
    /// Main-thread time of the last move of the parked spare to another window.
    private(set) var lastRetargetMilliseconds: Double?

    init(services: AppServices) {
        self.services = services
    }

    /// The new tab page is likely soon: a spare is worth its memory.
    var isLikely: Bool { usedThisSession || services.settings?.snapshot.newTabKind == .page }

    /// At launch: follow the key main window; park in the first visible one.
    func start() {
        services.agentTabs.recycle = { [weak self] view in self?.recycle(view) ?? false }
        observeWindows()
        if let window = NSApp.keyWindow.flatMap(mainWindow) ?? services.windows.controllers.compactMap(\.window).first(where: \.isVisible) {
            retarget(window)
        }
    }

    private func mainWindow(_ window: NSWindow) -> NSWindow? {
        services.windows.controllers.contains { $0.window === window } ? window : nil
    }

    /// The parked spare follows the key main window; a closing target hands
    /// it to another main window (window notifications, no scan).
    private func observeWindows() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window = window.flatMap(self.mainWindow) else { return }
                self.retarget(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.target else { return }
                let next = self.services.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
                if let next { self.retarget(next) } else { self.dropAll() }
            }
        })
    }

    /// Parks the spare in `window`: moves the parked page there (no reload),
    /// or starts one at the next quiet moment when there is none.
    func retarget(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        guard let content = window.contentView else { return }
        let start = ContinuousClock.now
        park(in: content)
        if !slot.shouldWarm { lastRetargetMilliseconds = Self.milliseconds(since: start) }
        scheduleWarm()
    }

    private func park(in content: NSView) {
        guard parking.superview !== content else { return }
        parking.frame = NewTabSpareParking.frame(in: content.bounds)
        parking.autoresizingMask = [.width, .height]
        content.addSubview(parking, positioned: .below, relativeTo: nil)
    }

    /// The spare for a new tab page in `window`, or nil (the page loads cold).
    /// A spare parked in another window is adopted all the same (a reparent).
    /// The caller adopts it at once; the next spare follows when input is quiet.
    func take(for window: NSWindow?) -> (view: AgentPaneView, crossWindow: Bool)? {
        usedThisSession = true
        observeWindows()
        if target == nil, let window { retarget(window) }
        defer { scheduleWarm() }
        guard let view = slot.take() else { return nil }
        return (view, window !== target)
    }

    /// A closed new tab page that never became a chat or a terminal: reset to
    /// the spare context (the page remounts its screen) and parked as the
    /// spare, so the close does no teardown and the pool builds nothing (R81).
    /// False when the slot is full or no page is likely.
    /// Why the last closed new tab page was not recycled (`debug.new_tab`).
    private(set) var lastRecycleRefusal: String?

    func recycle(_ view: AgentPaneView) -> Bool {
        lastRecycleRefusal = !slot.shouldWarm ? "slot full" : !isLikely ? "not likely" : view.model.newTab == nil ? "became a chat"
            : view.model.userTouched ? "touched by \(view.model.touchedBy ?? "?")" : target == nil ? "no target window" : nil
        guard lastRecycleRefusal == nil else { return false }
        BenchSpans.measure("pool.recycle") {
            view.adoptNewTab(NewTabPage.sparePage(services))
            // Out of the view tree now (as cheap as a close); back into the window at the next
            // quiet moment: putting a WKWebView back into a window costs a 15-20 ms commit, which
            // in the close frame dropped a frame on every Cmd-W (R81 bench).
            view.removeFromSuperview()
            slot.parked(view)
        }
        scheduleWarm()
        return true
    }

    func record(_ opening: Opening) {
        openings.append(opening)
        if openings.count > Self.maximumOpenings { openings.removeFirst(openings.count - Self.maximumOpenings) }
    }

    /// The parked spare, for `debug.new_tab`: its window number and page view.
    var spare: (window: Int, view: AgentPaneView)? {
        guard let view = parking.subviews.first as? AgentPaneView, let window = target else { return nil }
        return (window.windowNumber, view)
    }

    /// Drops the spare (memory pressure, the last window closing).
    func dropAll() {
        guard let view = slot.drop() else { return }
        view.removeFromSuperview()
        view.close()
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    // MARK: Warming

    /// Arms the quiet-input deadline; each key or click pushes it back.
    private func scheduleWarm() {
        guard isLikely, services.agentTabs.canHostChat, slot.shouldWarm || unparked != nil, target != nil else { return }
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

    /// A recycled spare not yet back in the window.
    private var unparked: AgentPaneView? {
        guard let view = slot.peek, view.superview == nil else { return nil }
        return view
    }

    private func warmNow() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let view = unparked, let content = target?.contentView {
            park(in: content)
            view.frame = parking.bounds
            view.autoresizingMask = [.width, .height]
            BenchSpans.measure("pool.park") { parking.addSubview(view) }
            return
        }
        guard isLikely, slot.shouldWarm, let content = target?.contentView,
              let view = BenchSpans.measure("pool.makeSpare", { services.agentTabs.makeSpare(NewTabPage.sparePage(services)) })
        else { return }
        park(in: content)
        view.frame = parking.bounds
        view.autoresizingMask = [.width, .height]
        parking.addSubview(view)
        slot.parked(view)
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

/// Where the spare waits: in the target window (WebKit renders only views in
/// a window and not hidden), fully transparent, never hit by the mouse, and
/// out of the accessibility tree. Adopting the spare reparents it into a pane.
final class NewTabSpareParking: NSView {
    /// The window content's size, far outside it. A web view's tracking areas
    /// ignore alpha and hit testing: parked over the content, the spare's
    /// cards hovered and set the cursor under the tab in front of it.
    static func frame(in bounds: NSRect) -> NSRect {
        NSRect(origin: NSPoint(x: bounds.minX - 100_000, y: bounds.minY - 100_000), size: bounds.size)
    }

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

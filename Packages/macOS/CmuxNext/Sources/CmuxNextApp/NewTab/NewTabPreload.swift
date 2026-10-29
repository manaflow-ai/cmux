import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInput
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// Instant new tab (plans/cmux-next/new-tab.md section 2) on the app's one preload slot
/// (``PagePreloadSlot``, plans/cmux-next/chrome-parity/p13-webui.md 3.D): the New Tab page is the
/// slot's default preload, as Chrome preloads its top-chrome WebUI
/// (chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.h). This adapter decides only
/// where and when; the slot loads the page visible, parks it and hands it over in the key's turn.
/// With feature `newTabParksHidden` the page parks hidden and the slot's cover shows in the key's
/// frame; without it the page parks rendering, as the New Tab spare always did.
///
/// - Where: the parking sits in the key main window (or the last key one) at the size of the pane
///   content Cmd-T fills there, so the adoption changes no size (hqacp-v2: a page parked at the
///   window's width showed for ~40 ms at that width after Cmd-T). It follows the key window (a
///   reparent, no reload) and that pane's size or focus once it settles (``fitSettle``).
/// - When: the launch's first preload starts 250 ms after the hooks arm and the page the launch
///   takes asks for the next one once it painted (cx-ec99); every later one waits for ``idleInput``
///   of quiet input, so making a web view never lands in the person's typing.
/// - Recycle: a closed, untouched New Tab page goes back to the slot at a quiet moment (R81).
/// - Memory pressure drops it, none is made or recycled until normal (``SpareMemoryConsumer``).
///
/// The slot holds one page for the whole app: while it holds another page (Settings, History,
/// Cloud) New Tab makes none, so the two never take turns evicting each other.
@MainActor
final class NewTabPreload {
    /// One adoption, for `debug.new_tab` (timing test, section 2.3).
    struct Opening {
        var spare: Bool
        /// The page was parked in another window than the one it opened in.
        var crossWindow: Bool
        /// Main-thread time from the open action to the page in its pane.
        var milliseconds: Double
        /// The page waited at another size than its pane's: the adoption resized it (hqacp-v2 flash).
        var refit = false
        /// The slot's cover showed in the key's frame (the page had parked).
        var covered = false
    }

    /// The New Tab page's key in the slot.
    static let key = PagePreloadSlot.Key("newTab")
    static let idleInput: Duration = .milliseconds(750)
    /// The launch's first preload waits this long after the hooks arm (cx-ec99).
    static let launchDelay: Duration = .milliseconds(250)
    /// A pane resize or focus change settles this long before the parked page follows it.
    static let fitSettle: Duration = .milliseconds(120)
    static let maximumOpenings = 64

    /// The app's one preload slot (`webUI.preload`).
    private let slot: PagePreloadSlot
    private let agentTabs: AgentTabStore, windows: WindowManager, appEvents: AppEvents
    /// What a preloaded page loads with (``NewTabPage/sparePage(_:)``); nil once the app is gone.
    private let sparePage: @MainActor () -> AgentPaneNewTab?
    private let parking = PagePreloadParkingView(frame: .zero)
    /// The main window the page parks in (the key one, or the last key one).
    private(set) weak var target: NSWindow?
    /// The quiet-input warm and the pane fit: work on a page nobody sees, so the background class.
    private let warmTimer: MainDeadline, fitTimer: MainDeadline
    /// The app's input tap: a warm waiting for quiet input observes its ``warmDelayingInput``.
    private let input: any InputObserving
    private var inputSubscription: InputSubscription?
    /// Warning or critical drops the page, and none is made or recycled until normal.
    private var spareMemory: SpareMemoryConsumer?
    private var usedThisSession = false
    /// No page before a New Tab page first showed this session (feature `pageRendererAtFirstShow`,
    /// Chrome's `PreloadMode::kPreloadOnMakeVisible`): Home idle then runs no renderer for a page nobody opened.
    private let preloadOnMakeVisible: Bool
    /// The page waits hidden in the slot and Cmd-T shows the slot's cover (feature `newTabParksHidden`).
    private let parksHidden: Bool
    /// Set by `start(holdingWarm: true)` until ``startWarming()``: no page is made meanwhile.
    private var warmHeld = false
    private var keyWatch: EventSubscription?, closeWatch: EventSubscription?
    /// A closed New Tab page waiting out of the window for a quiet moment: putting a WKWebView back
    /// into a window costs a 15-20 ms commit, which dropped a frame on every Cmd-W (R81 bench).
    private var recycled: AgentPaneView?
    /// The page taken last: its pane size and whether the slot's cover is on it.
    private var opening: (view: ObjectIdentifier, size: NSSize?, covered: Bool)?
    /// Whether this run has warmed a page yet (cx-ec99).
    private var warmedOnce = false
    private(set) var openings: [Opening] = []
    /// `debug.new_tab`: main-thread time of the last move of the parked page to another window, and
    /// why the last closed New Tab page was not recycled.
    private(set) var lastRetargetMilliseconds: Double?, lastRecycleRefusal: String?

    /// In place of ``AgentTabs/makeSpare(_:)`` (WebKit's first load, on the main thread): tests stall it.
    var makeSpare: ((AgentPaneNewTab) -> AgentPaneView?)?
    let webKit: WebKitSetupGate  // WebKit's setup on this host; a slow one gets no preload this run

    /// - Parameters:
    ///   - slot: The app's one preload slot; tests pass their own.
    ///   - agentTabs, windows, appEvents: The app's agent tabs, main windows and app notices.
    ///   - sparePage: What a preloaded page loads with.
    ///   - memory, input, deadlines: The app's memory coordinator (registered with at once), its
    ///     input tap, and the deadline scheduler of the warm and the fit (tests: a hand-fired one).
    ///   - preloadOnMakeVisible: The first page waits for the first New Tab page of the session.
    ///   - parksHidden: The page waits hidden and Cmd-T shows the slot's cover.
    init(slot: PagePreloadSlot, agentTabs: AgentTabStore, windows: WindowManager, appEvents: AppEvents,
         sparePage: @escaping @MainActor () -> AgentPaneNewTab?, memory: any MemoryConsumerRegistry,
         input: any InputObserving, deadlines: MainDeadlineScheduler, preloadOnMakeVisible: Bool, parksHidden: Bool) {
        (self.slot, self.agentTabs, self.windows, self.appEvents, self.sparePage) = (slot, agentTabs, windows, appEvents, sparePage)
        (self.input, self.preloadOnMakeVisible, self.parksHidden) = (input, preloadOnMakeVisible, parksHidden)
        warmTimer = MainDeadline(owner: "NewTabPreload.warm", workClass: .background, scheduler: deadlines)
        fitTimer = MainDeadline(owner: "NewTabPreload.fit", workClass: .background, scheduler: deadlines)
        webKit = WebKitSetupGate(deadlines: deadlines)
        spareMemory = SpareMemoryConsumer(
            name: "new-tab-spare", registry: memory, spares: { [weak self] in self?.spareView == nil ? 0 : 1 },
            drop: { [weak self] in self?.dropForPressure() }, refill: { [weak self] in self?.scheduleWarm() })
        // New Tab is the slot's default preload: when another page leaves the slot, it arms its own
        // (its own take arms the next one; its own drop arms none, so `drop_spare` leaves it cold).
        slot.observeEmptied { [weak self] key in if key != NewTabPreload.key { self?.scheduleWarm() } }
        // A web update dropped its own page: it makes one again from the new files.
        slot.observeStaleDropped { [weak self] key in if key == NewTabPreload.key { self?.scheduleWarm() } }
    }

    // MARK: Reading

    /// Whether memory pressure lets the adapter keep, make or recycle a page now (normal only).
    var allowsSpare: Bool { spareMemory?.allowsSpares ?? true }

    /// The New Tab page the slot holds, if it holds one.
    private var held: AgentPaneView? { slot.key == Self.key ? (slot.page as? AgentPanePreloadPage)?.pane : nil }

    /// The waiting page, held or recycled (`debug.memory` spares).
    var spareView: AgentPaneView? { held ?? recycled }

    /// The parked page, for `debug.new_tab`: its window number and page view.
    var spare: (window: Int, view: AgentPaneView)? {
        guard let view = held, let window = target else { return nil }
        return (window.windowNumber, view)
    }

    /// Where the held page is in the slot (`debug.new_tab`); nil when the slot holds no New Tab page.
    var phase: PagePreloadSlot.Phase? { held == nil ? nil : slot.phase }

    // MARK: Launch

    /// Probes WebKit's setup off the main thread, no page yet (a first load held launch >10 s, cua-2); an afterStartup post.
    func prewarm() {
        if agentTabs.canHostChat { webKit.probe { [weak self] in self?.scheduleWarm() } }
    }

    /// Follow the key main window; park in the first visible one. The launch posts this with
    /// `holdingWarm` after the first frame, so Cmd-T and Cmd-N find the hooks and the target window,
    /// and ``startWarming()`` at afterStartup, so the first load never lands in the second after the
    /// first frame.
    func start(holdingWarm: Bool = false) {
        warmHeld = holdingWarm
        agentTabs.recycle = { [weak self] view in self?.recycle(view) ?? false }
        // The first page of a new workspace (Cmd-N, an empty window's New Tab page) takes the
        // preload too, so a cold Cmd-N shows a page that already loaded (cx-ec99).
        agentTabs.takeSpare = { [weak self] in
            guard let self, let window = NSApp.keyWindow.flatMap(self.mainWindow) ?? self.target else { return nil }
            let start = ContinuousClock.now
            let taken = self.take(for: window, size: nil)
            self.record(.init(spare: taken != nil, crossWindow: taken?.crossWindow == true,
                              milliseconds: Self.milliseconds(since: start), covered: taken?.covered == true))
            return taken?.view
        }
        observeWindows()
        if let window = NSApp.keyWindow.flatMap(mainWindow) ?? windows.controllers.compactMap(\.window).first(where: \.isVisible) {
            retarget(window)
        }
    }

    /// Pages may be made from now on (the first one after ``launchDelay``).
    func startWarming() {
        warmHeld = false
        scheduleWarm()
    }

    private func mainWindow(_ window: NSWindow) -> NSWindow? {
        windows.controllers.contains { $0.window === window } ? window : nil
    }

    /// The parked page follows the key main window (the app's one key notice, ``AppEvents``).
    private func observeWindows() {
        guard keyWatch == nil else { return }
        keyWatch = appEvents.subscribe(NSWindow.didBecomeKeyNotification, owner: "NewTabPreload.key") { [weak self] in // raw-observer-allow: this is the AppEvents fan-out (one app observer), not a raw one
            guard let self, let window = NSApp.keyWindow.flatMap(self.mainWindow) else { return }
            self.retarget(window)
        }
    }

    /// A closing target hands the parked page to another main window (its own close notice, ``WindowEvents``).
    private func watchClose(of window: NSWindow) {
        closeWatch = WindowEvents.of(window).subscribe(NSWindow.willCloseNotification, owner: "NewTabPreload.close") { // raw-observer-allow: this is the WindowEvents fan-out (one observer per window), not a raw one
            [weak self, weak window] in
            guard let self, let window, window === self.target else { return }
            let next = self.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
            if let next { self.retarget(next) } else { self.dropAll() }
        }
    }

    // MARK: Where

    /// Parks in `window`: moves the parked page there (no reload), or starts one at the next quiet
    /// moment when there is none.
    func retarget(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        watchClose(of: window)
        guard let content = window.contentView else { return }
        let start = ContinuousClock.now
        park(in: content)
        if held != nil { lastRetargetMilliseconds = Self.milliseconds(since: start) }
        scheduleWarm()
    }

    /// Puts the parking in `content`, at the target pane's size.
    private func park(in content: NSView) {
        if parking.superview !== content {
            content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        fitParked()
    }

    /// The size of the pane content a Cmd-T in the target window fills: its focused pane's.
    private var targetPaneSize: NSSize? {
        guard let target, let pane = windows.controllers.first(where: { $0.window === target })?.content?.focusedPane
        else { return nil }
        let size = Self.newTabContentSize(in: pane)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// The size the page parks at now: the target pane's, else the window content's.
    private var parkSize: NSSize? {
        guard let content = parking.superview else { return nil }
        return targetPaneSize ?? content.bounds.size
    }

    /// Sizes the parking to the target pane now; the slot lays a held page out at that size and
    /// parks it again once it painted there, long before an adoption.
    private func fitParked() {
        guard let content = parking.superview, let size = parkSize else { return }
        let frame = PagePreloadParkingView.frame(in: content.bounds, size: size)
        guard parking.frame != frame else { return }
        BenchSpans.measure("pool.fit") {
            parking.frame = frame
            if held != nil { slot.refit(to: size) }
        }
    }

    /// A pane of `window` changed size, or its focus moved: the parked page follows the target
    /// pane once that settles (``fitSettle``). Nothing is scheduled while it fits.
    func paneLayoutDidChange(in window: NSWindow?) {
        guard let window, window === target, let content = parking.superview, let size = parkSize else { return }
        guard parking.frame != PagePreloadParkingView.frame(in: content.bounds, size: size) else { return }
        fitTimer.schedule(after: Self.fitSettle) { [weak self] in self?.fitParked() }
    }

    // MARK: Taking

    /// The preloaded New Tab page for `window`, or nil (the page loads cold). The slot hands it
    /// over in this turn: visible, with the slot's cover on top when it parked hidden at `size`, still in the parking, so
    /// the pane's install in the same turn moves it into the pane at the size it waited at. A page
    /// parked in another window is taken all the same (a reparent). The next preload follows when
    /// input is quiet. `refit` is true when the page waited at another size than `size` (nil: not
    /// known yet, Cmd-N): its adoption resizes it.
    func take(for window: NSWindow?, size: NSSize?) -> (view: AgentPaneView, crossWindow: Bool, refit: Bool, covered: Bool)? {
        usedThisSession = true
        observeWindows()
        if target == nil, let window { retarget(window) }
        defer { scheduleWarm() }
        guard let claimed = claim(size: size) else { return nil }
        let view = claimed.view
        // The launch's page took the preload: the next one starts once that page painted, not
        // after quiet input, so a Cmd-N right after launch finds a page loading (cx-ec99).
        if !warmedOnce {
            warmedOnce = true
            view.model.whenPainted { [weak self] in self?.warmNow() }
        }
        opening = (ObjectIdentifier(view), size, claimed.covered)
        return (view, window !== target, claimed.refit, claimed.covered)
    }

    /// The waiting page out of the slot (or the recycled one, never back in the window yet).
    private func claim(size: NSSize?) -> (view: AgentPaneView, refit: Bool, covered: Bool)? {
        if let view = recycled {
            recycled = nil
            return (view, size.map { view.frame.size != $0 } ?? false, false)
        }
        guard let view = held else { return nil }
        // An unknown size (Cmd-N: the new workspace's pane is not laid out yet) takes no cover: one of
        // the parked size would show stretched in that pane. `coverMove` covers the move at the pane's size.
        let frame = NSRect(origin: .zero, size: size ?? view.frame.size)
        guard let claim = slot.claim(Self.key, into: parking, frame: frame, cover: size != nil) else { return nil }
        return (view, claim.refit, claim.covered)
    }

    /// The pane size the last taken page shows at, when known.
    func openingSize(of view: AgentPaneView) -> NSSize? {
        opening.flatMap { $0.view == ObjectIdentifier(view) ? $0.size : nil }
    }

    /// Whether the last taken page carries the slot's cover until its first frame in the pane.
    func openingCovered(_ view: AgentPaneView) -> Bool {
        opening.map { $0.view == ObjectIdentifier(view) && $0.covered } ?? false
    }

    /// A closed New Tab page that never became a chat or a terminal: reset to the preload context
    /// (the page remounts its screen) and kept for the slot, so the close does no teardown and the
    /// adapter builds nothing (R81). False when a page waits already (the slot holds one page for
    /// the app) or no page is likely.
    func recycle(_ view: AgentPaneView) -> Bool {
        lastRecycleRefusal = view.model.neverPooled ? "another machine's page"
            : spareView != nil || slot.count > 0 ? "slot full" : view.model.newTab == nil ? "became a chat"
            : view.model.userTouched ? "touched by \(view.model.touchedBy ?? "?")" : target == nil ? "no target window"
            : !allowsSpare ? "memory pressure" : nil
        guard lastRecycleRefusal == nil else { return false }
        BenchSpans.measure("pool.recycle") {
            if let page = sparePage() { view.adoptNewTab(page) }
            // Out of the view tree now (as cheap as a close); into the parking at the next quiet moment.
            view.removeFromSuperview()
            recycled = view
        }
        scheduleWarm()
        return true
    }

    func record(_ opening: Opening) {
        openings.append(opening)
        if openings.count > Self.maximumOpenings { openings.removeFirst(openings.count - Self.maximumOpenings) }
    }

    // MARK: Dropping

    /// Memory pressure: drops the page and the warm that waits for quiet input.
    private func dropForPressure() {
        warmTimer.cancel()
        inputSubscription = nil
        dropAll()
    }

    /// Drops the waiting New Tab page (memory pressure, the last window closing, `debug.new_tab
    /// drop_spare`). Another page the slot holds stays.
    func dropAll() {
        if let view = recycled {
            recycled = nil
            view.close()
        }
        if held != nil { slot.drop() }
    }

    // MARK: When

    /// Arms the quiet-input deadline; each key or click pushes it back.
    private func scheduleWarm() {
        guard !warmHeld, allowsSpare, agentTabs.canHostChat, slot.count == 0 || recycled != nil, target != nil,
              usedThisSession || !preloadOnMakeVisible || recycled != nil else { return }
        if inputSubscription == nil {
            inputSubscription = input.observe(types: Self.warmDelayingInput) { [weak self] _ in self?.armWarmTimer() }
        }
        armWarmTimer()
    }

    /// The input that pushes a waiting warm back by ``idleInput``: key-downs, left and right
    /// mouse-downs and scrolls.
    static let warmDelayingInput: InputEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]

    private func armWarmTimer() {
        // Only the launch warm comes early: a `take()` that found nothing (it set
        // `usedThisSession`) must not make a web view in the person's keystroke.
        let launch = !warmedOnce && !usedThisSession
        warmedOnce = warmedOnce || launch
        warmTimer.schedule(after: launch ? Self.launchDelay : Self.idleInput) { [weak self] in self?.warmNow() }
    }

    /// `view` as the slot holds it: hidden while parked with `newTabParksHidden`, else rendering.
    private func preloadPage(_ view: AgentPaneView) -> any PreloadablePage { AgentPanePreloadPage(pane: view, parksHidden: parksHidden) }

    /// Hands the slot the recycled page, else a new one.
    private func warmNow() {
        inputSubscription = nil
        guard allowsSpare, let content = target?.contentView else { return }
        if let view = recycled {
            recycled = nil
            park(in: content)
            guard slot.count == 0, let size = parkSize else { return view.close() }
            let parked = BenchSpans.measure("pool.park") { slot.preload(Self.key, size: size, in: parking) { _ in preloadPage(view) } }
            if !parked { view.close() }
            return
        }
        guard webKit.state == .ready else { return webKit.probe { [weak self] in self?.scheduleWarm() } }
        guard slot.count == 0 else { return }
        park(in: content)
        guard let size = parkSize else { return }
        guard let page = sparePage() else { return }
        let start = ContinuousClock.now
        BenchSpans.measure("pool.makeSpare") {
            _ = slot.preload(Self.key, size: size, in: parking) { _ in
                guard let view = makeSpare?(page) ?? agentTabs.makeSpare(page) else { return nil }
                return preloadPage(view)
            }
        }
        if ContinuousClock.now - start > .seconds(1) { webKit.markSlow() } // it held the main thread
    }
}

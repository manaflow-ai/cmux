public import AppKit
public import CmuxNextBrowser
public import CmuxNextCompat
import CmuxNextWakeups
public import Foundation

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each on a fast Mac; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// - At the first frame (`start` runs from the App's first-frame hook), while
///   Chromium is the default engine (`browser.defaultEngine`) or for a user
///   who opened a Chromium tab in the last 7 days (`ChromiumUseRecord`), the
///   framework is mapped on a background thread (`CEFEngine.preload`, no
///   Chromium code runs, nothing on the main thread calls the loader).
///   While Chromium is the default engine, Chromium also starts right then
///   (`Reason.launch`, trigger `firstFrame`): `CefInitialize` runs on the main
///   thread as soon as the map and the launch prep that the first frame
///   released are done, after the frame and never before it. Every cmux page
///   (Home, agent chats) is a Chromium page under that default, so the first
///   one used to start Chromium itself when it asked, ~420 ms after the frame
///   (cmux23, 120 workspaces: frame 592 ms, `cef.initialize_start` 1014 ms,
///   always at `chromium_page.make_start`), and paid the whole start in its
///   own load. #43942 kept `CefInitialize` off the first frame when Home's
///   page was native and needed no Chromium; it now does.
/// - When a Chromium tab is likely, `CefInitialize` runs at the next idle
///   moment: no key or mouse input to this app for `Policy.idleInput` and no
///   menu tracking, waited for with one-shot deadlines (a deadline re-arms
///   for the rest of the quiet period after input, and the end of menu
///   tracking re-arms it; nothing polls). Likely means launch itself while
///   Chromium is the default engine (`browser.defaultEngine`, `Reason.launch`),
///   and otherwise a Chromium tab in any window (restored or not), the "+"
///   menu, the palette's Chromium entries, or switching the default to Chromium.
///   With WebKit as the default engine CEF stays lazy: a user who never opens
///   a Chromium tab never pays for it (AppServices+Chromium).
/// - Once Chromium runs, the next idle moment builds a spare Chromium window
///   (`CEFEngine.prepareSpareWindow`), so the first tab joins a live window,
///   and so does every later take of it: each pane's first Chromium tab
///   joins a live window instead of building one on the key's turn.
///   In a macOS 26 VM `CefInitialize` and the first window each held the main
///   thread for about 0.8 s (os-smoke, 2026-10-18): two idle steps, none at
///   the first tab.
@MainActor
public final class ChromiumWarmup {
    public enum Reason: String, Sendable {
        case restoredTab
        case newTabMenu
        case palette
        /// The default engine was just switched to Chromium.
        case defaultEngine
        /// New browser tabs default to Chromium: start it after launch,
        /// before any tab asks.
        case launch
    }

    public struct Policy: Sendable {
        /// From the first frame to a second look at the default engine: Chromium is the default by then
        /// (not at the first frame) => the launch warm start at the next idle moment (`Reason.launch`). A
        /// launch with Chromium the default at its first frame started it then (`startAtFirstFrame`).
        public var launchPreloadDelay: Duration = .seconds(3)
        public var idleInput: Duration = .milliseconds(750)
        /// Give up (stay lazy) when the app never goes idle this long.
        public var maxWait: Duration = .seconds(60)
        /// A Chromium tab opened this recently (`ChromiumUseRecord`) makes
        /// launch itself the warm-start signal.
        public var recentUse: TimeInterval = 7 * 24 * 60 * 60

        public init() {}
    }

    /// The engine's load and start steps the warm-up drives: the App's are the engine's own
    /// (`init(engine:)`); tests record which runs when.
    struct Loading {
        var isAvailable: @MainActor () -> Bool
        /// Starts the framework map on a background thread (`CEFEngine.preload`).
        var preload: @MainActor () -> Void
        var usedRecently: @MainActor (TimeInterval) async -> Bool
        var libraryLoadEnded: @MainActor () async -> Void
        /// `CefInitialize` on the main thread (`CEFEngine.warmStart`).
        var warmStart: @MainActor (String) async -> Void

        init(isAvailable: @escaping @MainActor () -> Bool, preload: @escaping @MainActor () -> Void,
             usedRecently: @escaping @MainActor (TimeInterval) async -> Bool,
             libraryLoadEnded: @escaping @MainActor () async -> Void, warmStart: @escaping @MainActor (String) async -> Void) {
            self.isAvailable = isAvailable
            self.preload = preload
            self.usedRecently = usedRecently
            self.libraryLoadEnded = libraryLoadEnded
            self.warmStart = warmStart
        }

        init(engine: CEFEngine) {
            self.init(isAvailable: { [weak engine] in engine?.availability == .available },
                      preload: { [weak engine] in engine?.preload() },
                      usedRecently: { [weak engine] window in await engine?.usedRecently(within: window) ?? false },
                      libraryLoadEnded: { [weak engine] in await engine?.libraryLoadEnded() },
                      warmStart: { [weak engine] reason in await engine?.warmStart(reason: reason) })
        }
    }

    private let engine: CEFEngine
    private let loading: Loading
    private let policy: Policy
    private let now: @MainActor () -> TimeInterval
    private let isTrackingMenu: @MainActor () -> Bool
    private let launchTimer: DemandTimer
    private let idleTimer: DemandTimer
    private let giveUpTimer: DemandTimer
    private var waiting = false
    private var menuObserver: MenuTracking?
    private var inputMonitor: Any?
    private var lastInput: TimeInterval = 0
    public private(set) var reason: Reason?
    /// What the next idle moment runs: `CefInitialize`, then the spare window.
    private var idleAction: (@MainActor () -> Void)?
    /// Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    private var defaultIsChromium: @MainActor () -> Bool = { false }
    /// Whether a Chromium page is being created: it builds its own window,
    /// and a spare built meanwhile would race it (os-smoke 2026-10-18).
    private var pagesPending: @MainActor () -> Bool = { false }
    /// The spare's idle moment came while a page was being made: it is made once the pages
    /// settle (`pagesSettled`), not at a later idle check.
    private var spareWaitsForPages = false
    /// Whether any web tab (a Chromium browser tab of any window, restored or opened) is open: the spare
    /// window and its spare page serve web tabs only, so none is made while none is open or likely.
    private var webTabsOpen: @MainActor () -> Bool = { true }
    /// A web tab is likely soon: the person reached for one (the "+" engine menu, the palette's Chromium
    /// entries, the default engine switched to Chromium, or a restored Chromium tab).
    private var webTabIntent = false
    /// A spare was due while no web tab was open or likely: it is made at the next idle moment once one is.
    private var spareDeferred = false
    private var stopped = false
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?

    /// - Parameter memoryPressure: the app's memory pressure events (`AppServices.memoryPressure`): a
    ///   warning or critical level closes the spare Chromium page and makes none until normal again
    ///   (`CEFEngine.holdSparePages`). Nil (tests): no such hold.
    public convenience init(
        engine: CEFEngine,
        policy: Policy = Policy(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking },
        memoryPressure: MemoryPressureEvents? = nil
    ) {
        self.init(engine: engine, loading: Loading(engine: engine), policy: policy, clock: clock, now: now,
                  isTrackingMenu: isTrackingMenu, memoryPressure: memoryPressure)
    }

    /// `init(engine:...)` with the load and start steps of `loading` (tests).
    init(
        engine: CEFEngine,
        loading: Loading,
        policy: Policy = Policy(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking },
        memoryPressure: MemoryPressureEvents? = nil
    ) {
        pressureObservation = memoryPressure?.observe { [weak engine] level in
            engine?.holdSparePages(level != .normal)
        }
        // The kernel never reports the level the app is already under; read it once now.
        memoryPressure?.refresh()
        self.engine = engine
        self.loading = loading
        self.policy = policy
        launchTimer = DemandTimer(owner: "ChromiumWarmup.preload", clock: clock)
        idleTimer = DemandTimer(owner: "ChromiumWarmup.idle", clock: clock)
        giveUpTimer = DemandTimer(owner: "ChromiumWarmup.maxWait", clock: clock)
        self.now = now
        self.isTrackingMenu = isTrackingMenu
    }

    /// Called at the first frame. For a user who opened a Chromium tab within `Policy.recentUse`, or
    /// while new tabs open in Chromium (`defaultIsChromium`), maps the framework now, off the main
    /// thread (`mapAtFirstFrame`); while new tabs open in Chromium, starts it now too
    /// (`startAtFirstFrame`: CefInitialize once the map is done, then the spare window at an idle
    /// moment). Anyone else pays nothing until a signal (`chromiumLikely`).
    public func start(
        defaultIsChromium: @escaping @MainActor () -> Bool,
        pagesPending: @escaping @MainActor () -> Bool = { false },
        webTabsOpen: @escaping @MainActor () -> Bool = { true }
    ) {
        guard !launchTimer.isScheduled, loading.isAvailable() else { return }
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        self.webTabsOpen = webTabsOpen
        // Whenever no spare window is ready (taken, or a tab started Chromium itself), the next
        // idle moment makes one, so a new Chromium tab joins a live window (CEFSpareWindow, PL-cef-tab).
        engine.onSpareWindowNeeded = { [weak self] in self?.spareNeeded() }
        // The page the person waits for arrived: a spare that waited for it is made at the next idle moment.
        engine.onPagesArrived = { [weak self] in self?.pagesSettled() }
        launchTimer.schedule(after: policy.launchPreloadDelay) { @MainActor [weak self] in
            guard let self, !stopped else { return }
            // While new browser tabs open in Chromium, any browser tab is a Chromium tab: start it
            // at the first idle moment after launch, so no Cmd-Shift-L pays CefInitialize.
            if self.defaultIsChromium() { chromiumLikely(.launch) }
        }
        mapAtFirstFrame()
        if defaultIsChromium() { startAtFirstFrame() }
    }

    /// While Chromium is the default engine, every cmux page is a Chromium page: start it at the first
    /// frame instead of when the first page asks (~420 ms later at 120 workspaces) or after
    /// `launchPreloadDelay` and an idle moment. Only `CefInitialize` runs on the main thread, in a task
    /// of its own after the first-frame hooks; the map and the launch prep stay off it, and both start
    /// only once the frame committed (`CEFRuntime.initializeAfter`), so the frame pays nothing. A page
    /// that asks meanwhile shares this start (`CEFRuntime.start` is one start for all callers).
    private func startAtFirstFrame() {
        guard reason == nil, !engine.isRunning else { return }
        reason = .launch
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            guard let self, !stopped else { return }
            await loading.warmStart("firstFrame")
            warmStarted()
        }
    }

    /// Starts the framework map now, at the first frame, for a person likely to open a Chromium page:
    /// Chromium is the default engine, or they opened a Chromium tab within `Policy.recentUse`. The map
    /// runs on a background thread (`CEFEngine.preload`); the main thread takes its result only when a
    /// page first asks for Chromium (or the warm start's idle moment), so the first Chromium page of
    /// the launch's first seconds no longer waits for a load that began 3 s after the frame.
    private func mapAtFirstFrame() {
        if defaultIsChromium() { return loading.preload() }
        // task-owner: one launch check per process; reads one small file off the main thread
        Task { [weak self] in
            guard let self, await loading.usedRecently(policy.recentUse), !stopped else { return }
            loading.preload()
        }
    }

    /// No spare Chromium window is ready: the next idle moment makes one, unless a warm start
    /// already waits for one (it ends with the spare).
    private func spareNeeded() {
        guard !stopped, engine.isRunning, !waiting else { return }
        warmStarted()
    }

    /// A Chromium tab is likely soon: map the framework now and run
    /// `CefInitialize` at the next idle moment. Once per process.
    public func chromiumLikely(_ reason: Reason) {
        if Self.signalsWebTab(reason) { webTabLikely() }
        guard self.reason == nil, loading.isAvailable(), !engine.isRunning else { return }
        self.reason = reason
        loading.preload()
        // The idle wait starts once the framework is mapped, so CefInitialize
        // never waits on a cold load and then lands in input.
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.loading.libraryLoadEnded()
            guard let self, !stopped else { return }
            waitForIdle { [weak self] in
                // task-owner: one warm start per process; CEFEngine owns its lifetime
                Task { [weak self] in
                    await self?.loading.warmStart(reason.rawValue)
                    self?.warmStarted()
                }
            }
        }
    }

    /// Chromium runs: build the spare window (CEFSpareWindow) at the next
    /// idle moment, a main-thread step of its own, so neither step lands in
    /// the first tab's open.
    private func warmStarted() {
        guard !stopped, engine.isRunning else { return }
        // Chromium also runs for agent chats and cmux pages, which never use the web tabs' spare: it is a
        // web tab's window and page. With none open or likely, Home held both (a hidden window, an
        // about:blank placeholder and a frozen spare page, each with its renderer) for nothing. Once a
        // cmux page opened, the pages' own store keeps a spare window for the next page (CEFSpareWindow).
        let webSpare = Self.makesSpare(webTabsOpen: webTabsOpen(), webTabIntent: webTabIntent)
        spareDeferred = !webSpare
        guard webSpare || engine.wantsPageSpareWindow else { return }
        waitForIdle { [weak self] in
            guard let self else { return }
            // A page being made builds its own window: the spare waits until the pages settle
            // (`pagesSettled`) instead of racing that window (os-smoke 2026-10-18). So does a page the
            // person waits for (`CEFEngine.pagesArriving`): a window built or a spare page made in its
            // load held its first paint for seconds under load (Leo 2026-11-05).
            if pagesPending() || engine.pagesArriving {
                spareWaitsForPages = true
                return
            }
            // One window per idle moment: the pages' spare first (a cmux page opens more often than a
            // web tab's pane); its window coming up asks for the next idle moment (`onSpareWindowNeeded`).
            if engine.wantsPageSpareWindow, engine.preparePageSpareWindow() { return }
            if webSpare { engine.prepareSpareWindow() }
        }
    }

    /// A web tab is open now or likely soon: a spare deferred for want of one is made at the next idle
    /// moment, so the tab after this one joins a live window.
    public func webTabLikely() {
        webTabIntent = true
        // A web spare released while every web tab slept (`CEFSpareWindow.webPagesChanged`) is made again.
        engine.webPageLikely()
        guard spareDeferred, !waiting else { return }
        warmStarted()
    }

    /// Reasons that mean a web tab, not just Chromium: launch with Chromium as the default engine starts
    /// Chromium for agent chats and cmux pages too, so it alone makes no spare.
    nonisolated static func signalsWebTab(_ reason: Reason) -> Bool { reason != .launch }

    /// Whether the spare window and its page are worth making now: a web tab is open, or one is likely.
    nonisolated static func makesSpare(webTabsOpen: Bool, webTabIntent: Bool) -> Bool { webTabsOpen || webTabIntent }

    /// No Chromium page is being made any more (the cache's pending set emptied), or the page the
    /// person waited for arrived: a spare that waited for that is made at the next idle moment.
    public func pagesSettled() {
        guard spareWaitsForPages else { return }
        spareWaitsForPages = false
        warmStarted()
    }

    /// Runs `action` at the next idle moment (no input for `idleInput`, no
    /// menu tracking), or never when the app is not idle within `maxWait`.
    private func waitForIdle(_ action: @escaping @MainActor () -> Void) {
        idleAction = action
        lastInput = now()
        waiting = true
        installInputMonitor()
        armIdle(after: policy.idleInput)
        giveUpTimer.schedule(after: policy.maxWait) { @MainActor [weak self] in self?.finishWaiting() }
    }

    public func stop() {
        stopped = true
        launchTimer.cancel()
        finishWaiting()
    }

    private func armIdle(after delay: Duration) {
        idleTimer.schedule(after: delay) { @MainActor [weak self] in self?.idleDeadline() }
    }

    /// The quiet period may have ended: warm up, or wait for the rest of it
    /// (input came meanwhile) or for menu tracking to end.
    private func idleDeadline() {
        guard waiting else { return }
        if isTrackingMenu() {
            guard menuObserver == nil else { return }
            // The tracking menu's end (MenuTracking, in AppKit's own post) arms the idle wait again.
            let menus = MenuTracking()
            menus.subscribe { [weak self] change in
                guard case .ended = change, let self else { return }
                self.removeMenuObserver()
                self.armIdle(after: self.policy.idleInput)
            }
            menuObserver = menus
            return
        }
        let quiet = now() - lastInput
        let remaining = policy.idleInput.inSeconds - quiet
        guard remaining <= 0 else { return armIdle(after: .seconds(remaining)) }
        let action = idleAction
        finishWaiting()
        action?()
    }

    /// True when no input reached this app for `idleInput` and no menu is
    /// tracking.
    public func isIdle(_ policy: Policy) -> Bool {
        guard !isTrackingMenu() else { return false }
        let quiet = now() - lastInput
        return quiet >= policy.idleInput.inSeconds
    }

    /// Records input while a warm start waits (no monitor otherwise).
    public func noteInput() { lastInput = now() }

    private func installInputMonitor() {
        guard inputMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .scrollWheel, .mouseMoved]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.noteInput()
            return event
        }
    }

    private func finishWaiting() {
        waiting = false
        idleAction = nil
        idleTimer.cancel()
        giveUpTimer.cancel()
        removeMenuObserver()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func removeMenuObserver() {
        menuObserver = nil
    }
}

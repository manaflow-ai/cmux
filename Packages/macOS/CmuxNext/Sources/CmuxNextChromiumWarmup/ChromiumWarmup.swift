public import AppKit
public import CmuxNextBrowser
import CmuxNextWakeups
public import Foundation

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each on a fast Mac; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// - A few seconds after launch, while Chromium is the default engine
///   (`browser.defaultEngine`), Chromium starts at the next idle moment
///   (`Reason.launch`); otherwise, for a user who opened a Chromium tab in the
///   last 7 days (`ChromiumUseRecord`), the framework is mapped on a
///   background thread (`CEFEngine.preload`, no Chromium code runs).
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
        public var launchPreloadDelay: Duration = .seconds(3)
        public var idleInput: Duration = .milliseconds(750)
        /// Give up (stay lazy) when the app never goes idle this long.
        public var maxWait: Duration = .seconds(60)
        /// A Chromium tab opened this recently (`ChromiumUseRecord`) makes
        /// launch itself the warm-start signal.
        public var recentUse: TimeInterval = 7 * 24 * 60 * 60

        public init() {}
    }

    private let engine: CEFEngine
    private let policy: Policy
    private let now: @MainActor () -> TimeInterval
    private let isTrackingMenu: @MainActor () -> Bool
    private let launchTimer: DemandTimer
    private let idleTimer: DemandTimer
    private let giveUpTimer: DemandTimer
    private var waiting = false
    private var menuObserver: (any NSObjectProtocol)?
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
    private var stopped = false

    public init(
        engine: CEFEngine,
        policy: Policy = Policy(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking }
    ) {
        self.engine = engine
        self.policy = policy
        launchTimer = DemandTimer(owner: "ChromiumWarmup.preload", clock: clock)
        idleTimer = DemandTimer(owner: "ChromiumWarmup.idle", clock: clock)
        giveUpTimer = DemandTimer(owner: "ChromiumWarmup.maxWait", clock: clock)
        self.now = now
        self.isTrackingMenu = isTrackingMenu
    }

    private var isAvailable: Bool { engine.availability == .available }

    /// `launchPreloadDelay` after launch, for a user who opened a Chromium
    /// tab within `Policy.recentUse`: maps the framework, and while new tabs
    /// open in Chromium (`defaultIsChromium`) starts it (CefInitialize, then
    /// the spare window, at idle moments). Anyone else pays nothing until a
    /// signal (`chromiumLikely`).
    public func start(defaultIsChromium: @escaping @MainActor () -> Bool, pagesPending: @escaping @MainActor () -> Bool = { false }) {
        guard !launchTimer.isScheduled, isAvailable else { return }
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        // Whenever no spare window is ready (taken, or a tab started Chromium itself), the next
        // idle moment makes one, so a new Chromium tab joins a live window (CEFSpareWindow, PL-cef-tab).
        engine.onSpareWindowNeeded = { [weak self] in self?.spareNeeded() }
        launchTimer.schedule(after: policy.launchPreloadDelay) { @MainActor [weak self] in
            guard let self, !stopped else { return }
            // While new browser tabs open in Chromium, any browser tab is a Chromium tab: start it
            // at the first idle moment after launch, so no Cmd-Shift-L pays CefInitialize.
            if self.defaultIsChromium() { return chromiumLikely(.launch) }
            // task-owner: one launch check per process; reads one small file off the main thread
            Task { [weak self] in
                guard let self, await engine.usedRecently(within: policy.recentUse), !stopped else { return }
                engine.preload()
            }
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
        guard self.reason == nil, isAvailable, !engine.isRunning else { return }
        self.reason = reason
        engine.preload()
        // The idle wait starts once the framework is mapped, so CefInitialize
        // never waits on a cold load and then lands in input.
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.engine.libraryLoadEnded()
            guard let self, !stopped else { return }
            waitForIdle { [weak self] in
                // task-owner: one warm start per process; CEFEngine owns its lifetime
                Task { [weak self] in
                    await self?.engine.warmStart(reason: reason.rawValue)
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
        waitForIdle { [weak self] in
            guard let self else { return }
            // A page being made builds its own window: the spare waits until the pages settle
            // (`pagesSettled`) instead of racing that window (os-smoke 2026-10-18).
            if pagesPending() {
                spareWaitsForPages = true
                return
            }
            engine.prepareSpareWindow()
        }
    }

    /// No Chromium page is being made any more (the cache's pending set emptied): a spare that
    /// waited for that is made at the next idle moment.
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
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    guard let self else { return }
                    self.removeMenuObserver()
                    self.armIdle(after: self.policy.idleInput)
                }
            }
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
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }
}

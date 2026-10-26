public import AppKit
public import CmuxNextBrowser
public import CmuxNextCompat
public import CmuxNextInputCore
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
///   While cmux pages use Chromium (`pagesSpare`, the `pagesSpareWindow`
///   feature), the warm start's spare step also makes the pages profile
///   (`CEFEngine.beginPagesProfile`), and the idle moment after the default
///   profile's spare comes up builds the pages spare, so a cmux page's key
///   joins a live window too (p13-webui-016). One spare per kind; each take
///   asks for the next at the following idle moment. When pages leave
///   Chromium (`pagesSpareChanged`), the untaken pages spare closes.
///   In a macOS 26 VM `CefInitialize` and the first window each held the main
///   thread for about 0.8 s (os-smoke, 2026-10-18): two idle steps, none at
///   the first tab.
/// - Spare windows follow memory pressure through one memory consumer (``SpareMemoryConsumer``,
///   Chrome's spare rule): at warning or critical none is made or given back
///   (`ChromiumWarmupEngine.holdSpareWindows`) and the untaken ones stay, as Chrome keeps its spare
///   renderer; critical closes them too (`closeUntakenSpareWindows`, p13-webui-047). Back at normal
///   the next idle moment makes one again. `CefInitialize` itself is not held: it builds no spare.
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

    private let engine: any ChromiumWarmupEngine
    private let policy: Policy
    private let now: @MainActor () -> TimeInterval
    private let isTrackingMenu: @MainActor () -> Bool
    private let launchTimer: DemandTimer
    private let idleTimer: DemandTimer
    private let giveUpTimer: DemandTimer
    private var waiting = false
    /// The pending idle wait is a spare window's (`warmStarted`), not `CefInitialize`'s: memory
    /// pressure cancels only that one.
    private var waitingForSpare = false
    private var menuObserver: (any NSObjectProtocol)?
    /// The app's input tap: a warm start waiting for an idle moment observes it.
    private let input: any InputObserving
    private var inputSubscription: InputSubscription?
    private var lastInput: TimeInterval = 0
    public private(set) var reason: Reason?
    /// What the next idle moment runs: `CefInitialize`, then the spare window.
    private var idleAction: (@MainActor () -> Void)?
    /// Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    private var defaultIsChromium: @MainActor () -> Bool = { false }
    /// Whether a Chromium page is being created: it builds its own window,
    /// and a spare built meanwhile would race it (os-smoke 2026-10-18).
    private var pagesPending: @MainActor () -> Bool = { false }
    /// Whether to keep a spare window of the cmux pages profile (pages use Chromium and the
    /// `pagesSpareWindow` feature is on); read at each spare's idle moment.
    private var pagesSpare: @MainActor () -> Bool = { false }
    /// The spare's idle moment came while a page was being made: it is made once the pages
    /// settle (`pagesSettled`), not at a later idle check.
    private var spareWaitsForPages = false
    private var stopped = false
    /// The spare windows' memory consumer: no new spare at warning or critical, none again until
    /// normal; critical closes the untaken ones.
    private var spareMemory: SpareMemoryConsumer?

    /// - Parameters:
    ///   - engine: The Chromium engine to start.
    ///   - input: The app's input tap; a wait for an idle moment observes its keys, clicks, drags,
    ///     scrolls and moves.
    ///   - memory: The app's memory coordinator; the spare windows register with it at once.
    public init(
        engine: any ChromiumWarmupEngine,
        input: any InputObserving,
        memory: any MemoryConsumerRegistry,
        policy: Policy = Policy(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking }
    ) {
        self.engine = engine
        self.input = input
        self.policy = policy
        launchTimer = DemandTimer(owner: "ChromiumWarmup.preload", clock: clock)
        idleTimer = DemandTimer(owner: "ChromiumWarmup.idle", clock: clock)
        giveUpTimer = DemandTimer(owner: "ChromiumWarmup.maxWait", clock: clock)
        self.now = now
        self.isTrackingMenu = isTrackingMenu
        spareMemory = SpareMemoryConsumer(
            name: "chromium-spare-windows", registry: memory, closing: .atCritical,
            spares: { [weak self] in self?.engine.spareWindowCount ?? 0 },
            hold: { [weak self] in self?.sparesHeld(closingUntaken: false) },
            drop: { [weak self] in self?.sparesHeld(closingUntaken: true) }, refill: { [weak self] in self?.sparesAllowed() })
    }

    private var isAvailable: Bool { engine.availability == .available }

    /// Whether memory pressure lets a spare window be made now (normal only).
    private var allowsSpare: Bool { spareMemory?.allowsSpares ?? true }

    /// Memory pressure rose above normal: no spare is made or given back, and a spare's pending idle
    /// wait ends now with its input subscription and timers (as `NewTabPreload.dropForPressure`
    /// cancels its armed warm), instead of waking the main thread for up to `maxWait` for a spare that
    /// cannot be made. A `CefInitialize` wait goes on: it builds no spare. At warning the untaken spares
    /// stay, as Chrome keeps its spare renderer; at critical (`closingUntaken`) they close.
    private func sparesHeld(closingUntaken: Bool) {
        engine.holdSpareWindows(true)
        if closingUntaken { engine.closeUntakenSpareWindows() }
        spareWaitsForPages = false
        if waitingForSpare { finishWaiting() }
    }

    /// Memory pressure fell back to normal: spares may be made and given back again, the next
    /// one at the next idle moment.
    private func sparesAllowed() {
        engine.holdSpareWindows(false)
        spareNeeded()
    }

    /// `launchPreloadDelay` after launch, for a user who opened a Chromium
    /// tab within `Policy.recentUse`: maps the framework, and while new tabs
    /// open in Chromium (`defaultIsChromium`) starts it (CefInitialize, then
    /// the spare window, at idle moments). Anyone else pays nothing until a
    /// signal (`chromiumLikely`).
    ///
    /// - Parameters:
    ///   - defaultIsChromium: Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    ///   - pagesPending: Whether a Chromium page is being made (a spare then waits for `pagesSettled`).
    ///   - pagesSpare: Whether to keep a spare window of the cmux pages profile too.
    public func start(defaultIsChromium: @escaping @MainActor () -> Bool, pagesPending: @escaping @MainActor () -> Bool = { false },
                      pagesSpare: @escaping @MainActor () -> Bool = { false }) {
        guard !launchTimer.isScheduled, isAvailable else { return }
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        self.pagesSpare = pagesSpare
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
        guard !stopped, allowsSpare, engine.isRunning, !waiting else { return }
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
            waitForIdle { [weak self] in self?.warmStart(reason) }
        }
    }

    /// Starts Chromium now, with no idle wait: its start costs the main thread nothing (the Chromium Host,
    /// placed by ``ChromiumHostLaunchStart``, p08-startup-046). Once per process, as ``chromiumLikely(_:)``;
    /// the first spare window still waits for an idle moment.
    public func startWithoutIdleWait(_ reason: Reason) {
        guard self.reason == nil, isAvailable, !engine.isRunning, !stopped else { return }
        self.reason = reason
        warmStart(reason)
    }

    /// Starts Chromium for `reason`, then makes the first spare window at the next idle moment.
    private func warmStart(_ reason: Reason) {
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.engine.warmStart(reason: reason.rawValue)
            self?.warmStarted()
        }
    }

    /// Whether cmux pages keep a Chromium spare changed (`pagesSpare`, read again now): kept, the
    /// next idle moment builds the pages spare; no longer kept (pages left Chromium), the untaken
    /// pages spare closes now. Nothing to do before Chromium runs: the first spare step reads
    /// `pagesSpare` itself.
    public func pagesSpareChanged() {
        guard !stopped, engine.isRunning else { return }
        if pagesSpare() { return spareNeeded() }
        engine.dropPagesSpareWindow()
    }

    /// Chromium runs: build the next missing spare window (CEFSpareWindow, the default
    /// profile's, then the pages profile's) at the next idle moment, a main-thread step of its
    /// own, so neither step lands in the first tab's or page's open.
    private func warmStarted() {
        guard !stopped, allowsSpare, engine.isRunning else { return }
        waitForIdle(forSpare: true) { [weak self] in
            // Pressure that comes during the wait ends it (`sparesHeld`); the return to normal asks again.
            guard let self else { return }
            // A page being made builds its own window: the spare waits until the pages settle
            // (`pagesSettled`) instead of racing that window (os-smoke 2026-10-18).
            if pagesPending() {
                spareWaitsForPages = true
                return
            }
            engine.prepareSpareWindow(pages: pagesSpare())
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
    /// menu tracking), or never when the app is not idle within `maxWait`. Internal, not private:
    /// tests start a wait without a running engine. `forSpare`: the wait is a spare window's, which
    /// memory pressure cancels (`sparesHeld`).
    func waitForIdle(forSpare: Bool = false, _ action: @escaping @MainActor () -> Void) {
        idleAction = action
        lastInput = now()
        waiting = true
        waitingForSpare = forSpare
        observeInput()
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
    /// (input came meanwhile) or for menu tracking to end. Internal, not private: tests reach the
    /// idle moment without advancing a clock.
    func idleDeadline() {
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

    /// Records input while a warm start waits (no subscription otherwise).
    public func noteInput() { lastInput = now() }

    /// The input that restarts the quiet period: key-downs, mouse-downs, left drags, scrolls and
    /// moves (ups, other drags and modifier changes do not).
    static let quietEndingInput: InputEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                    .leftMouseDragged, .scrollWheel, .mouseMoved]

    private func observeInput() {
        guard inputSubscription == nil else { return }
        inputSubscription = input.observe(types: Self.quietEndingInput) { [weak self] _ in self?.noteInput() }
    }

    private func finishWaiting() {
        waiting = false
        waitingForSpare = false
        idleAction = nil
        idleTimer.cancel()
        giveUpTimer.cancel()
        removeMenuObserver()
        inputSubscription = nil
    }

    private func removeMenuObserver() {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }
}

/// What ``ChromiumWarmup`` drives: Chromium's start steps and its spare windows. ``CEFEngine`` in the
/// app; tests pass a fake that records the spare steps.
@MainActor
public protocol ChromiumWarmupEngine: AnyObject {
    var availability: BrowserEngineAvailability { get }
    /// Whether Chromium runs (`CefInitialize` finished).
    var isRunning: Bool { get }
    /// True when this app opened a Chromium tab within `window`.
    func usedRecently(within window: TimeInterval) async -> Bool
    /// Maps the framework on a background thread; no Chromium code runs.
    func preload()
    /// Returns once the framework load that `preload` started ended.
    func libraryLoadEnded() async
    /// Starts Chromium (`CefInitialize`) for `reason`.
    func warmStart(reason: String) async
    /// Builds the next missing spare window, the pages profile's too with `pages`; `pages` false
    /// closes an untaken pages spare. True when one started.
    @discardableResult
    func prepareSpareWindow(pages: Bool) -> Bool
    /// Stops keeping a pages spare window and closes an untaken one.
    func dropPagesSpareWindow()
    /// How many untaken spare windows are up (or being built).
    var spareWindowCount: Int { get }
    /// Holds the spare windows for memory pressure: `true` refuses new ones and give-backs until
    /// `false`, and keeps the untaken ones.
    func holdSpareWindows(_ held: Bool)
    /// Closes the untaken spare windows (critical memory pressure).
    func closeUntakenSpareWindows()
    /// Runs when a wanted spare window is not ready, so the warmup makes one at an idle moment.
    var onSpareWindowNeeded: (@MainActor () -> Void)? { get set }
}

extension CEFEngine: ChromiumWarmupEngine {}

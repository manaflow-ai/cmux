public import AppKit
import CmuxNextBrowser
import CmuxNextCompat
public import CmuxNextInputCore
public import CmuxNextWakeups
public import Foundation

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each on a fast Mac; architecture.md 5a, the one allowed
/// exception) land neither in the launch nor in the middle of user input.
///
/// Both steps are afterStartup tasks of the launch's ``StartupScheduler``, as Chrome posts its
/// deferred browser work through `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc): nothing here runs before `startup_complete`, a
/// released main task runs in a frame with no pending input, and no timer of this type runs at
/// launch. Each step's main-thread work runs inside its post.
///
/// - After startup, while Chromium is the default engine (`browser.defaultEngine`), Chromium
///   starts at the next idle moment (`Reason.launch`); otherwise, for a user who opened a
///   Chromium tab in the last 7 days (`ChromiumUseRecord`), the framework is mapped on a
///   background thread (`CEFEngine.preload`, no Chromium code runs).
/// - When a Chromium tab is likely, the framework is mapped and `CefInitialize` runs at the next
///   idle moment. Likely means launch itself while Chromium is the default engine, and otherwise
///   a Chromium tab in any window (restored or not), the "+" menu, the palette's Chromium
///   entries, or switching the default to Chromium. With WebKit as the default engine CEF stays
///   lazy: a user who never opens a Chromium tab never pays for it (AppServices+Chromium).
///   A person's signal (the menu, the palette, the default switch) maps the framework at once, on
///   a background thread, so a tab picked right after skips the cold load; a hidden need (a
///   restored tab, launch) maps it after startup.
/// - Once Chromium runs, the next idle moment builds a spare Chromium window
///   (`CEFEngine.prepareSpareWindow`), so the first tab joins a live window, and so does every
///   later take of it. While cmux pages use Chromium (`pagesSpare`, the `pagesSpareWindow`
///   feature), the warm start's spare step also makes the pages profile
///   (`CEFEngine.beginPagesProfile`), and the idle moment after the default profile's spare comes
///   up builds the pages spare, so a cmux page's key joins a live window too (p13-webui-016). One
///   spare per kind; each take asks for the next at the following idle moment. When pages leave
///   Chromium (`pagesSpareChanged`), the untaken pages spare closes. In a macOS 26 VM
///   `CefInitialize` and the first window each held the main thread for about 0.8 s (os-smoke,
///   2026-10-18): two idle steps, none at the first tab.
///
/// An idle moment is the step's post running (after startup, no pending input) with no key or
/// mouse input to this app for `Policy.idleInput` and no menu tracking. The quiet period runs from
/// the app's last input (the input tap's last event), not from the request, so an idle app runs the
/// step in its post. When input came, one ``DemandTimer`` waits for the rest of the quiet period and
/// posts the step again: it is armed only after input while a step is pending, and cancelled when
/// the step is posted. The end of menu tracking re-arms it. A step not run within `Policy.maxWait`
/// of its first post is given up. Nothing polls.
@MainActor
public final class ChromiumWarmup {
    public enum Reason: String, Sendable {
        case restoredTab
        case newTabMenu
        case palette
        /// The default engine was just switched to Chromium.
        case defaultEngine
        /// New browser tabs default to Chromium: start it after startup,
        /// before any tab asks.
        case launch

        /// A person's signal (the "+" menu, the palette, the default switch): the framework is
        /// mapped at once. A hidden need (a restored tab, launch) maps it after startup.
        var isPersonSignal: Bool {
            switch self {
            case .newTabMenu, .palette, .defaultEngine: true
            case .restoredTab, .launch: false
            }
        }
    }

    public struct Policy: Sendable {
        public var idleInput: Duration = .milliseconds(750)
        /// Give up (stay lazy) when the app is not idle this long after a step's post first ran.
        public var maxWait: Duration = .seconds(60)
        /// A Chromium tab opened this recently (`ChromiumUseRecord`) makes
        /// launch itself the warm-start signal.
        public var recentUse: TimeInterval = 7 * 24 * 60 * 60

        public init() {}
    }

    /// One idle-moment step: `CefInitialize` or the spare window.
    private struct Step {
        let name: StaticString
        let action: @MainActor () -> Void
    }

    private let engine: any ChromiumWarmupEngine
    private let policy: Policy
    private let now: @MainActor () -> TimeInterval
    private let isTrackingMenu: @MainActor () -> Bool
    /// The idle predicate's one timer: armed only after input while a step is pending.
    private let idleTimer: DemandTimer
    /// The launch's scheduler: every deferred preload and every step is an afterStartup post on it.
    private let startup: StartupScheduler
    /// The step waiting for an idle moment, and whether its post is queued.
    private var step: Step?
    private var stepPosted = false
    /// When the step's post first ran (after startup), for `maxWait`; nil before.
    private var waitStarted: TimeInterval?
    private var started = false
    private var menuObserver: MainActorObservation?
    /// The app's input tap: a pending step observes it.
    private let input: any InputObserving
    private var inputSubscription: InputSubscription?
    private var lastInput: TimeInterval = 0
    public private(set) var reason: Reason?
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

    /// - Parameters:
    ///   - engine: The Chromium engine to start (``CEFEngine``; a fake in tests).
    ///   - input: The app's input tap; a step waiting for an idle moment observes its keys, clicks,
    ///     drags, scrolls and moves, and the quiet period starts at its last event.
    ///   - startup: The launch's scheduler (`LaunchOrder.startup`).
    ///   - clock: The idle timer's clock.
    public init(
        engine: any ChromiumWarmupEngine,
        input: any InputObserving,
        startup: StartupScheduler,
        policy: Policy = Policy(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking }
    ) {
        self.engine = engine
        self.input = input
        self.startup = startup
        self.policy = policy
        idleTimer = DemandTimer(owner: "ChromiumWarmup.idle", clock: clock)
        self.now = now
        self.isTrackingMenu = isTrackingMenu
    }

    private var isAvailable: Bool { engine.availability == .available }

    /// After startup, for a user who opened a Chromium tab within `Policy.recentUse`: maps the
    /// framework, and while new tabs open in Chromium (`defaultIsChromium`) starts it
    /// (`CefInitialize`, then the spare window, at idle moments). Anyone else pays nothing until a
    /// signal (`chromiumLikely`). Once per process; the decision is an afterStartup post.
    ///
    /// - Parameters:
    ///   - defaultIsChromium: Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    ///   - pagesPending: Whether a Chromium page is being made (a spare then waits for `pagesSettled`).
    ///   - pagesSpare: Whether to keep a spare window of the cmux pages profile too.
    public func start(defaultIsChromium: @escaping @MainActor () -> Bool, pagesPending: @escaping @MainActor () -> Bool = { false },
                      pagesSpare: @escaping @MainActor () -> Bool = { false }) {
        guard !started, isAvailable else { return }
        started = true
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        self.pagesSpare = pagesSpare
        // Whenever no spare window is ready (taken, or a tab started Chromium itself), the next
        // idle moment makes one, so a new Chromium tab joins a live window (CEFSpareWindow, PL-cef-tab).
        engine.onSpareWindowNeeded = { [weak self] in self?.spareNeeded() }
        post("ChromiumWarmup.launch") { [weak self] in self?.launchCheck() }
    }

    /// While new browser tabs open in Chromium, any browser tab is a Chromium tab: start it at the
    /// first idle moment after startup, so no Cmd-Shift-L pays CefInitialize. Otherwise map the
    /// framework for a recent Chromium user.
    private func launchCheck() {
        guard !stopped else { return }
        if defaultIsChromium() {
            guard claim(.launch) else { return }
            return preloadThenInitialize(.launch)
        }
        // task-owner: one launch check per process; reads one small file off the main thread
        Task { [weak self] in
            guard let self, await engine.usedRecently(within: policy.recentUse), !stopped else { return }
            engine.preload()
        }
    }

    /// No spare Chromium window is ready: the next idle moment makes one, unless a step already
    /// waits (a warm start ends with the spare).
    private func spareNeeded() {
        guard !stopped, engine.isRunning, step == nil else { return }
        warmStarted()
    }

    /// A Chromium tab is likely soon: map the framework (now for a person's signal, after startup for
    /// a hidden need) and run `CefInitialize` at the next idle moment after startup. Once per process.
    public func chromiumLikely(_ reason: Reason) {
        guard claim(reason) else { return }
        guard reason.isPersonSignal else {
            return post("ChromiumWarmup.preload") { [weak self] in self?.preloadThenInitialize(reason) }
        }
        preloadThenInitialize(reason)
    }

    /// Records the first reason; false when one was recorded, or Chromium is unavailable or runs.
    private func claim(_ reason: Reason) -> Bool {
        guard self.reason == nil, isAvailable, !engine.isRunning else { return false }
        self.reason = reason
        return true
    }

    /// Maps the framework (a background thread), and once it is mapped asks for `CefInitialize` at
    /// an idle moment, so CefInitialize never waits on a cold load and then lands in input.
    private func preloadThenInitialize(_ reason: Reason) {
        guard !stopped else { return }
        engine.preload()
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.engine.libraryLoadEnded()
            guard let self, !stopped else { return }
            request("ChromiumWarmup.cefInitialize") { [weak self] in self?.initialize(reason) }
        }
    }

    /// The step: `CefInitialize` in this post's turn (the idle moment), then the spare window.
    private func initialize(_ reason: Reason) {
        guard engine.initializeLoaded(reason: reason.rawValue) else { return }
        warmStarted()
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
        guard !stopped, engine.isRunning else { return }
        request("ChromiumWarmup.spareWindow") { [weak self] in
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

    /// Runs `action` at the next idle moment after startup (an afterStartup post that finds no input
    /// for `idleInput` and no menu tracking), or never when the app is not idle within `maxWait` of
    /// the first post. Internal, not private: tests ask for a step without a running engine.
    func request(_ name: StaticString, _ action: @escaping @MainActor () -> Void) {
        guard !stopped else { return }
        step = Step(name: name, action: action)
        // The request is not input: the quiet period runs from the app's last event. The tap keeps
        // only its last one, so any event counts here (an up or a modifier change follows the key or
        // click that ended the quiet period).
        lastInput = max(lastInput, input.lastDispatched?.timestamp ?? 0)
        waitStarted = nil
        observeInput()
        postStep()
    }

    public func stop() {
        stopped = true
        finishWaiting()
    }

    /// Whether the idle timer is armed: only after input while a step waits, so never during launch.
    var idleTimerArmed: Bool { idleTimer.isScheduled }

    /// Posts the pending step once; the idle timer ends here.
    private func postStep() {
        guard let step, !stepPosted else { return }
        idleTimer.cancel()
        stepPosted = true
        post(step.name) { [weak self] in self?.stepPostRan() }
    }

    /// An afterStartup main post: held until startup completes, then run in a frame with no pending input.
    private func post(_ name: StaticString, _ work: @escaping @MainActor @Sendable () -> Void) {
        startup.post(.afterStartup, name, on: .main, work)
    }

    /// The step's post ran (after startup, no pending input): run it when the app is idle, else
    /// wait for the rest of the quiet period or for menu tracking to end.
    private func stepPostRan() {
        stepPosted = false
        guard !stopped, let step else { return }
        if waitStarted == nil { waitStarted = now() }
        guard !gaveUp() else { return }
        guard isIdle(policy) else { return waitForQuiet() }
        finishWaiting()
        step.action()
    }

    /// Gives the step up when its post first ran `maxWait` ago: the post, the idle deadline and the
    /// end of menu tracking each ask this before they wait again.
    private func gaveUp() -> Bool {
        guard let waitStarted, now() - waitStarted >= policy.maxWait.inSeconds else { return false }
        finishWaiting()
        return true
    }

    /// Arms the idle timer for the rest of the quiet period (input came), or waits for the end of
    /// menu tracking.
    private func waitForQuiet() {
        if isTrackingMenu() {
            guard menuObserver == nil else { return }
            menuObserver = MainActorObservation(NSMenu.didEndTrackingNotification) { [weak self] in self?.menuTrackingEnded() }
            return
        }
        let remaining = policy.idleInput.inSeconds - (now() - lastInput)
        armIdle(after: .seconds(max(remaining, 0)))
    }

    /// Menu tracking ended: it counts as input, so the quiet period starts now.
    func menuTrackingEnded() {
        removeMenuObserver()
        guard step != nil, !stepPosted, !gaveUp() else { return }
        noteInput()
        armIdle(after: policy.idleInput)
    }

    private func armIdle(after delay: Duration) {
        idleTimer.schedule(after: delay) { @MainActor [weak self] in self?.idleDeadline() }
    }

    /// The quiet period may have ended: post the step, or wait for the rest of it (input came
    /// meanwhile) or for menu tracking to end. Internal, not private: tests fire the deadline by hand.
    func idleDeadline() {
        guard step != nil, !stepPosted, !gaveUp() else { return }
        guard isIdle(policy) else { return waitForQuiet() }
        postStep()
    }

    /// True when no input reached this app for `idleInput` and no menu is
    /// tracking.
    public func isIdle(_ policy: Policy) -> Bool {
        guard !isTrackingMenu() else { return false }
        let quiet = now() - lastInput
        return quiet >= policy.idleInput.inSeconds
    }

    /// Records input while a step waits (no subscription otherwise).
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
        step = nil
        waitStarted = nil
        idleTimer.cancel()
        removeMenuObserver()
        inputSubscription = nil
    }

    private func removeMenuObserver() {
        menuObserver = nil
    }
}

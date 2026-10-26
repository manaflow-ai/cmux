public import CmuxNextBrowser
public import CmuxNextWakeups
public import Foundation

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each on a fast Mac; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// Every step is an idle task of the app's main-thread scheduler (``ChromiumWarmupIdle``,
/// `MainWorkScheduler.postIdle`): it runs in an idle period (no input pending, no frame client
/// running, no budgeted work waiting), never in the turn that asked for it and never inside a
/// person's input response. Nothing here polls or arms a timer of its own: Chrome's idle tasks
/// (`third_party/blink/renderer/platform/scheduler/common/idle_helper.h`) and after-startup work
/// (`content/browser/after_startup_task_utils.cc`).
///
/// - At the first idle period after ``start(defaultIsChromium:pagesPending:pagesSpare:)`` (called
///   after the first frame; idle work waits for the settled startup phase), while Chromium is the
///   default engine (`browser.defaultEngine`), Chromium starts (`Reason.launch`); otherwise, for a
///   user who opened a Chromium tab in the last 7 days (`ChromiumUseRecord`), the framework is
///   mapped on a background thread (`CEFEngine.preload`, no Chromium code runs).
/// - When a Chromium tab is likely, the framework is mapped and `CefInitialize` runs in the first
///   idle period after the load. Likely means launch itself while Chromium is the default engine
///   (`Reason.launch`), and otherwise a Chromium tab in any window (restored or not), the "+" menu,
///   the palette's Chromium entries, or switching the default to Chromium. With WebKit as the
///   default engine CEF stays lazy: a user who never opens a Chromium tab never pays for it
///   (AppServices+Chromium).
/// - Once Chromium runs, an idle task builds the next missing spare Chromium window
///   (`CEFEngine.prepareSpareWindow`), so each pane's first Chromium tab joins a live window
///   instead of building one on the key's turn. The refill has a ``Policy/spareMaxDelay`` of
///   500 ms: past it the step runs as background work, so a busy app (an animation, an agent's
///   stream) still has a spare for the next Cmd-T (p06-scheduler.md, risk 6). While cmux pages use
///   Chromium (`pagesSpare`, the `pagesSpareWindow` feature), the warm start's spare step also
///   makes the pages profile (`CEFEngine.beginPagesProfile`), and the step after the default
///   profile's spare comes up builds the pages spare, so a cmux page's key joins a live window too
///   (p13-webui-016). One spare per kind; each take asks for the next. When pages leave Chromium
///   (`pagesSpareChanged`), the untaken pages spare closes.
/// - A step that comes while a menu tracks waits for the menu to close, and is posted again then.
///
/// In a macOS 26 VM `CefInitialize` and the first window each held the main thread for about
/// 0.8 s (os-smoke, 2026-10-18): two idle steps, none at the first tab.
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
        /// A Chromium tab opened this recently (`ChromiumUseRecord`) makes
        /// launch itself the warm-start signal.
        public var recentUse: TimeInterval = 7 * 24 * 60 * 60
        /// The longest a spare window refill waits for an idle period before it runs as
        /// background work (the idle task's `maxDelay`).
        public var spareMaxDelay: Duration = .milliseconds(500)

        public init() {}
    }

    /// One warmup step, each an idle task of its own.
    enum Step: String {
        /// The launch check: start Chromium, or map the framework for a recent Chromium user.
        case launch
        /// `CefInitialize`.
        case initialize
        /// The next missing spare window.
        case spare

        var owner: String { "ChromiumWarmup.\(rawValue)" }
    }

    private let engine: any ChromiumWarmupEngine
    private let idle: any ChromiumWarmupIdle
    private let policy: Policy
    private let isTrackingMenu: @MainActor () -> Bool
    private let observeMenuEnd: MenuEndObserving
    /// The observation of the menu's end while a step waits for it.
    private var menuEnd: AnyObject?
    private var started = false
    /// The steps queued as idle tasks or waiting for a menu to close: one task per step.
    private(set) var pending: Set<Step> = []
    /// The steps that came while a menu tracked, in order: posted again when it closes.
    private var afterMenu: [Step] = []
    public private(set) var reason: Reason?
    /// Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    private var defaultIsChromium: @MainActor () -> Bool = { false }
    /// Whether a Chromium page is being created: it builds its own window,
    /// and a spare built meanwhile would race it (os-smoke 2026-10-18).
    private var pagesPending: @MainActor () -> Bool = { false }
    /// Whether to keep a spare window of the cmux pages profile (pages use Chromium and the
    /// `pagesSpareWindow` feature is on); read at each spare step.
    private var pagesSpare: @MainActor () -> Bool = { false }
    /// The spare step came while a page was being made: it is posted again once the pages settle
    /// (`pagesSettled`), not at a later request.
    private var spareWaitsForPages = false
    private var stopped = false

    /// - Parameters:
    ///   - engine: The Chromium engine to start.
    ///   - idle: Where the steps are posted as idle tasks (the app's `MainWorkScheduler`).
    ///   - isTrackingMenu: Whether a menu tracks now (a step then waits for it to close).
    ///   - observeMenuEnd: Observes the end of menu tracking (the app: an observation of
    ///     `NSMenu.didEndTrackingNotification`); the observation stops when its token is released.
    public init(
        engine: any ChromiumWarmupEngine,
        idle: any ChromiumWarmupIdle,
        policy: Policy = Policy(),
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking },
        observeMenuEnd: @escaping MenuEndObserving
    ) {
        self.engine = engine
        self.idle = idle
        self.policy = policy
        self.isTrackingMenu = isTrackingMenu
        self.observeMenuEnd = observeMenuEnd
    }

    /// Calls its argument at each end of menu tracking until the returned token is released.
    public typealias MenuEndObserving = @MainActor (_ ended: @escaping @MainActor () -> Void) -> AnyObject

    private var isAvailable: Bool { engine.availability == .available }

    /// At the next idle period, for a user who opened a Chromium tab within `Policy.recentUse`:
    /// maps the framework, and while new tabs open in Chromium (`defaultIsChromium`) starts it
    /// (CefInitialize, then the spare window, each in an idle period). Anyone else pays nothing
    /// until a signal (`chromiumLikely`). Once per process.
    ///
    /// - Parameters:
    ///   - defaultIsChromium: Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    ///   - pagesPending: Whether a Chromium page is being made (a spare then waits for `pagesSettled`).
    ///   - pagesSpare: Whether to keep a spare window of the cmux pages profile too.
    public func start(defaultIsChromium: @escaping @MainActor () -> Bool, pagesPending: @escaping @MainActor () -> Bool = { false },
                      pagesSpare: @escaping @MainActor () -> Bool = { false }) {
        guard !started, !stopped, isAvailable else { return }
        started = true
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        self.pagesSpare = pagesSpare
        // Whenever no spare window is ready (taken, or a tab started Chromium itself), an idle
        // task makes one, so a new Chromium tab joins a live window (CEFSpareWindow, PL-cef-tab).
        engine.onSpareWindowNeeded = { [weak self] in self?.spareNeeded() }
        post(.launch)
    }

    /// No spare Chromium window is ready: an idle task makes one (one queued spare step serves
    /// every request before it runs; it reads the spare state then).
    private func spareNeeded() {
        guard !stopped, engine.isRunning, !spareWaitsForPages else { return }
        post(.spare)
    }

    /// A Chromium tab is likely soon: map the framework now and run
    /// `CefInitialize` in the first idle period after the load. Once per process.
    public func chromiumLikely(_ reason: Reason) {
        guard self.reason == nil, isAvailable, !engine.isRunning, !stopped else { return }
        self.reason = reason
        engine.preload()
        // The step is posted once the framework is mapped, so CefInitialize never waits on a
        // cold load and then lands in input.
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.engine.libraryLoadEnded()
            self?.post(.initialize)
        }
    }

    /// Whether cmux pages keep a Chromium spare changed (`pagesSpare`, read again now): kept, an
    /// idle task builds the pages spare; no longer kept (pages left Chromium), the untaken pages
    /// spare closes now. Nothing to do before Chromium runs: the first spare step reads
    /// `pagesSpare` itself.
    public func pagesSpareChanged() {
        guard !stopped, engine.isRunning else { return }
        if pagesSpare() { return spareNeeded() }
        engine.dropPagesSpareWindow()
    }

    /// No Chromium page is being made any more (the cache's pending set emptied): a spare step
    /// that waited for that is posted again.
    public func pagesSettled() {
        guard spareWaitsForPages else { return }
        spareWaitsForPages = false
        spareNeeded()
    }

    /// Ends the warmup: steps already posted do nothing when they run.
    public func stop() {
        stopped = true
        pending = []
        afterMenu = []
        menuEnd = nil
    }

    /// Posts `step` as an idle task unless one is pending (it runs the same step later).
    private func post(_ step: Step) {
        guard !stopped, !pending.contains(step) else { return }
        pending.insert(step)
        idle.postIdleStep(owner: step.owner, maxDelay: step == .spare ? policy.spareMaxDelay : nil, file: #fileID, line: #line) { [weak self] in
            self?.run(step)
        }
    }

    /// `step`'s idle task runs: while a menu tracks it waits for the menu to close and is posted
    /// again then. Internal, not private: tests run the posted steps through their fake poster.
    func run(_ step: Step) {
        guard !stopped, pending.contains(step) else { return }
        if isTrackingMenu() { return waitForMenu(step) }
        pending.remove(step)
        switch step {
        case .launch: launchCheck()
        case .initialize: initialize()
        case .spare: prepareSpare()
        }
    }

    /// The launch step: while new browser tabs open in Chromium, any browser tab is a Chromium
    /// tab, so Chromium starts now and no Cmd-Shift-L pays CefInitialize; otherwise a recent
    /// Chromium user gets the framework mapped.
    private func launchCheck() {
        if defaultIsChromium() { return chromiumLikely(.launch) }
        // task-owner: one launch check per process; reads one small file off the main thread
        Task { [weak self] in
            guard let self, await engine.usedRecently(within: policy.recentUse), !stopped else { return }
            engine.preload()
        }
    }

    /// The `CefInitialize` step; Chromium that a tab started meanwhile goes on to the spare.
    private func initialize() {
        guard let reason, !engine.isRunning else { return warmStarted() }
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { [weak self] in
            await self?.engine.warmStart(reason: reason.rawValue)
            self?.warmStarted()
        }
    }

    /// Chromium runs: the next missing spare window (CEFSpareWindow, the default profile's, then
    /// the pages profile's) is an idle step of its own, so neither step lands in the first tab's
    /// or page's open.
    private func warmStarted() {
        guard !stopped, engine.isRunning else { return }
        post(.spare)
    }

    private func prepareSpare() {
        guard engine.isRunning else { return }
        // A page being made builds its own window: the spare waits until the pages settle
        // (`pagesSettled`) instead of racing that window (os-smoke 2026-10-18).
        if pagesPending() {
            spareWaitsForPages = true
            return
        }
        engine.prepareSpareWindow(pages: pagesSpare())
    }

    /// `step` came while a menu tracks: it stays pending, and the end of menu tracking posts it
    /// again (with the other steps that came meanwhile).
    private func waitForMenu(_ step: Step) {
        if !afterMenu.contains(step) { afterMenu.append(step) }
        guard menuEnd == nil else { return }
        menuEnd = observeMenuEnd { [weak self] in self?.menuEnded() }
    }

    private func menuEnded() {
        menuEnd = nil
        let steps = afterMenu
        afterMenu = []
        for step in steps {
            pending.remove(step)
            post(step)
        }
    }
}

/// Where ``ChromiumWarmup`` posts its steps: the app's `MainWorkScheduler` (its idle class);
/// tests pass a fake that runs the posted steps by hand.
@MainActor
public protocol ChromiumWarmupIdle: AnyObject {
    /// Queues `body` for the main thread's next idle period, never inline. With `maxDelay`, a
    /// body that has not run by then runs as background work.
    ///
    /// - Parameters:
    ///   - owner: The task's owner in the scheduler's board.
    ///   - maxDelay: The longest the body waits for idle time; nil waits for it however long.
    ///   - file: The posting file, for the board.
    ///   - line: The posting line, for the board.
    ///   - body: The step.
    func postIdleStep(owner: String, maxDelay: Duration?, file: StaticString, line: UInt, _ body: @escaping @MainActor () -> Void)
}

extension MainWorkScheduler: ChromiumWarmupIdle {
    public func postIdleStep(owner: String, maxDelay: Duration?, file: StaticString, line: UInt, _ body: @escaping @MainActor () -> Void) {
        postIdle(owner: owner, maxDelay: maxDelay, file: file, line: line) { _ in body() }
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
    /// Runs when a wanted spare window is not ready, so the warmup makes one at an idle moment.
    var onSpareWindowNeeded: (@MainActor () -> Void)? { get set }
}

extension CEFEngine: ChromiumWarmupEngine {}

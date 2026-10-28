public import CmuxNextBrowser
public import CmuxNextCompat
public import CmuxNextInputCore
public import Foundation

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each on a fast Mac; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// Every step is an idle task of the app's main-thread scheduler (``ChromiumWarmupIdle``,
/// `MainWorkScheduler.postIdle`), posted once startup settled (`StartupPhase.settled`), never run
/// in the turn that asked for it. Nothing here polls: Chrome's idle tasks
/// (`third_party/blink/renderer/platform/scheduler/common/idle_helper.h`) and after-startup work
/// (`chrome/browser/after_startup_task_utils.cc`).
///
/// - The two steps that hold the main thread (`CefInitialize`, a spare window) cannot fit in any
///   idle deadline, so they start only in a slot that may run past it (a long idle period, or past
///   the step's `maxDelay` as background work, never in an open input response; Chrome's
///   `IdleHelper::CanExceedIdleDeadlineIfRequired`), and only after ``Policy/inputQuiet`` (750 ms)
///   with no input from the person: one gap between two keys is never enough. A step that comes
///   sooner waits for the rest of the quiet with one deadline (Chrome delays its long idle period
///   while a gesture is expected, `MainThreadSchedulerImpl::CanEnterLongIdlePeriod`), and a step
///   in a short period between frames is posted for the next period.
/// - Every step has a `maxDelay` (``Policy/warmStartMaxDelay``, ``Policy/spareMaxDelay``): an app
///   that never goes idle (an animation, an agent's stream) still warms up, as background work.
/// - Once startup settled, while Chromium is the default engine (`browser.defaultEngine`),
///   Chromium starts (`Reason.launch`); otherwise, for a user who opened a Chromium tab in the
///   last 7 days (`ChromiumUseRecord`), the framework is mapped on a background thread
///   (`CEFEngine.preload`, no Chromium code runs).
/// - When a Chromium tab is likely, the framework is mapped and `CefInitialize` is posted once it
///   loaded. Likely means launch itself while Chromium is the default engine (`Reason.launch`),
///   and otherwise a Chromium tab in any window (restored or not), the "+" menu, the palette's
///   Chromium entries, or switching the default to Chromium. With WebKit as the default engine CEF
///   stays lazy: a user who never opens a Chromium tab never pays for it (AppServices+Chromium).
/// - Once Chromium runs, an idle task builds the next missing spare Chromium window
///   (`CEFEngine.prepareSpareWindow`), so each pane's first Chromium tab joins a live window
///   instead of building one on the key's turn (p06-scheduler.md, risk 6). While cmux pages use
///   Chromium (`pagesSpare`, the `pagesSpareWindow` feature), the warm start's spare step also
///   makes the pages profile (`CEFEngine.beginPagesProfile`), and the step after the default
///   profile's spare comes up builds the pages spare, so a cmux page's key joins a live window too
///   (p13-webui-016). One spare per kind; each take asks for the next. When pages leave Chromium
///   (`pagesSpareChanged`), the untaken pages spare closes.
/// - A step that comes while a menu tracks waits for the menu to close, and is posted again then.
/// - Spare windows follow memory pressure through one memory consumer (``SpareMemoryConsumer``,
///   Chrome's spare rule): at warning or critical none is made or given back
///   (`ChromiumWarmupEngine.holdSpareWindows`), a queued spare step is taken back, and the untaken
///   spares stay, as Chrome keeps its spare renderer; critical closes them too
///   (`closeUntakenSpareWindows`, p13-webui-047). Back at normal an idle task makes one again.
///   `CefInitialize` itself is not held: it builds no spare.
/// - With the Chromium Host (``Placement/host(spareWindows:)``, p01-process-086) the start holds the
///   main thread only for its shim calls, so `CefInitialize` is an idle step that waits for neither
///   the input quiet nor a long slot. The spare window step follows it as in process: content makes
///   its spare RenderProcessHost only after a navigation took a process
///   (`content/browser/renderer_host/spare_render_process_host_manager_impl.cc`,
///   `PrepareForFutureRequests`), so after a warm start nothing else warms a renderer for the first tab
///   until cmux can ask the host for `SpareRenderProcessHostManager::WarmupSpare`. The bench-only
///   feature `chromiumHostNoSpareWindow` drops the spare window in host mode, the arm that measures
///   the first tab without it.
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
        /// How long the person gives no input before `CefInitialize` or a spare window build
        /// starts: longer than the gaps of typing (100-300 ms between keys).
        public var inputQuiet: Duration = .milliseconds(750)
        /// The longest the launch check and `CefInitialize` wait for idle time before they run as
        /// background work.
        public var warmStartMaxDelay: Duration = .seconds(5)
        /// The longest a spare window refill waits for idle time before it runs as background work.
        public var spareMaxDelay: Duration = .milliseconds(500)

        public init() {}
    }

    /// Where Chromium's browser process runs, as the warm-up sees it (`CEFRuntimeSource.backend`).
    public nonisolated struct Placement: Sendable, Equatable {
        /// `CefInitialize` holds the main thread (in this process, about 80-160 ms): its step waits
        /// for the input quiet and a slot that may run past its deadline. False with the Chromium Host,
        /// whose start holds it only for the shim calls.
        public var startHoldsMainThread: Bool
        /// Whether the warm-up keeps spare Chromium windows (`CEFSpareWindow`).
        public var keepsSpareWindows: Bool

        /// Chromium in this process: its start and each new window hold the main thread.
        public static let inProcess = Placement(startHoldsMainThread: true, keepsSpareWindows: true)

        /// The Chromium Host: its start holds the main thread only for the shim calls. It keeps the
        /// spare windows (the first tab's warm renderer after a warm start) unless `spareWindows` is
        /// false (the bench-only `chromiumHostNoSpareWindow`).
        public static func host(spareWindows: Bool = true) -> Placement {
            Placement(startHoldsMainThread: false, keepsSpareWindows: spareWindows)
        }

        public init(startHoldsMainThread: Bool, keepsSpareWindows: Bool) {
            (self.startHoldsMainThread, self.keepsSpareWindows) = (startHoldsMainThread, keepsSpareWindows)
        }

        /// The placement of `backend` (`CEFRuntimeSource.backend`); `hostNoSpareWindow` (the bench-only
        /// `chromiumHostNoSpareWindow`) is read only for the Chromium Host.
        public init(backend: BrowserBackend, hostNoSpareWindow: Bool) {
            self = backend == .host ? .host(spareWindows: !hostNoSpareWindow) : .inProcess
        }
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

        /// Whether the step holds the main thread for long where Chromium is placed: it then waits
        /// for a quiet person and for a slot that may run past its deadline.
        func holdsMainThread(_ placement: Placement) -> Bool {
            switch self {
            case .launch: false
            case .initialize: placement.startHoldsMainThread
            case .spare: true
            }
        }
    }

    private let engine: any ChromiumWarmupEngine
    private let idle: any ChromiumWarmupIdle
    /// The app's input tap: its last dispatched event dates the person's last input.
    private let input: any InputObserving
    private let policy: Policy
    private let isTrackingMenu: @MainActor () -> Bool
    private let observeMenuEnd: MenuEndObserving
    /// The observation of the menu's end while a step waits for it.
    private var menuEnd: AnyObject?
    /// The deadline at the end of the input quiet while a step waits for it.
    private var quietEnd: AnyObject?
    private var started = false
    /// The steps posted and not run yet (held for the settle, queued as idle tasks, or waiting for
    /// a menu or the quiet): one task per step.
    private(set) var pending: Set<Step> = []
    /// When each queued step's `maxDelay` ends (on ``ChromiumWarmupIdle/uptime``): a step posted
    /// again keeps it.
    private var due: [Step: Duration] = [:]
    /// The steps that came while a menu tracked, in order: posted again when it closes.
    private var afterMenu: [Step] = []
    /// The steps that came before the input quiet ended, in order: posted again when it does.
    private var afterQuiet: [Step] = []
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
    /// Where Chromium runs (``start(defaultIsChromium:pagesPending:pagesSpare:placement:)``): in process until then.
    private(set) var placement = Placement.inProcess
    /// The placement ``start(defaultIsChromium:pagesPending:pagesSpare:placement:)`` set; nil before it
    /// (`debug.cef` `warmup_spare_windows`, which the bench's host arms check).
    public var startedPlacement: Placement? { started ? placement : nil }
    /// The spare windows' memory consumer: no new spare at warning or critical, none again until
    /// normal; critical closes the untaken ones.
    private var spareMemory: SpareMemoryConsumer?

    /// - Parameters:
    ///   - engine: The Chromium engine to start.
    ///   - idle: Where the steps are posted as idle tasks, held for the settled startup and delayed
    ///     for the input quiet (the app's `MainDeadlineScheduler`).
    ///   - input: The app's input tap (its ``InputObserving/lastDispatched`` event).
    ///   - memory: The app's memory coordinator; the spare windows register with it at once.
    ///   - isTrackingMenu: Whether a menu tracks now (a step then waits for it to close). The app
    ///     reads `NSMenu`'s begin and end of tracking, not the run loop's `eventTracking` mode,
    ///     which a window drag or a live resize also runs in, with no menu end after it.
    ///   - observeMenuEnd: Observes the end of menu tracking (the app: an observation of
    ///     `NSMenu.didEndTrackingNotification`); the observation stops when its token is released.
    public init(
        engine: any ChromiumWarmupEngine,
        idle: any ChromiumWarmupIdle,
        input: any InputObserving,
        memory: any MemoryConsumerRegistry,
        policy: Policy = Policy(),
        isTrackingMenu: @escaping @MainActor () -> Bool,
        observeMenuEnd: @escaping MenuEndObserving
    ) {
        self.engine = engine
        self.idle = idle
        self.input = input
        self.policy = policy
        self.isTrackingMenu = isTrackingMenu
        self.observeMenuEnd = observeMenuEnd
        spareMemory = SpareMemoryConsumer(
            name: "chromium-spare-windows", registry: memory, closing: .atCritical,
            spares: { [weak self] in self?.engine.spareWindowCount ?? 0 },
            hold: { [weak self] in self?.sparesHeld(closingUntaken: false) },
            drop: { [weak self] in self?.sparesHeld(closingUntaken: true) }, refill: { [weak self] in self?.sparesAllowed() })
    }

    /// Calls its argument at each end of menu tracking until the returned token is released.
    public typealias MenuEndObserving = @MainActor (_ ended: @escaping @MainActor () -> Void) -> AnyObject

    private var isAvailable: Bool { engine.availability == .available }

    /// Whether memory pressure lets a spare window be made now (normal only).
    private var allowsSpare: Bool { spareMemory?.allowsSpares ?? true }

    /// Memory pressure rose above normal: no spare is made or given back, and a queued spare step is
    /// taken back now with its menu or quiet wait (as `NewTabPreload.dropForPressure` cancels its
    /// armed warm), instead of running for a spare that cannot be made. A `CefInitialize` step goes
    /// on: it builds no spare. At warning the untaken spares stay, as Chrome keeps its spare
    /// renderer; at critical (`closingUntaken`) they close.
    private func sparesHeld(closingUntaken: Bool) {
        engine.holdSpareWindows(true)
        if closingUntaken { engine.closeUntakenSpareWindows() }
        spareWaitsForPages = false
        cancel(.spare)
    }

    /// Memory pressure fell back to normal: spares may be made and given back again, the next one
    /// in an idle task.
    private func sparesAllowed() {
        engine.holdSpareWindows(false)
        spareNeeded()
    }

    /// Once startup settled, for a user who opened a Chromium tab within `Policy.recentUse`: maps
    /// the framework, and while new tabs open in Chromium (`defaultIsChromium`) starts it
    /// (CefInitialize, then the spare window, each an idle step). Anyone else pays nothing until a
    /// signal (`chromiumLikely`). Once per process.
    ///
    /// - Parameters:
    ///   - defaultIsChromium: Whether new browser tabs open in Chromium (`browser.defaultEngine`).
    ///   - pagesPending: Whether a Chromium page is being made (a spare then waits for `pagesSettled`).
    ///   - pagesSpare: Whether to keep a spare window of the cmux pages profile too.
    ///   - placement: Where Chromium runs: whether its start holds the main thread and whether spare
    ///     windows are kept.
    public func start(defaultIsChromium: @escaping @MainActor () -> Bool, pagesPending: @escaping @MainActor () -> Bool = { false },
                      pagesSpare: @escaping @MainActor () -> Bool = { false }, placement: Placement = .inProcess) {
        guard !started, !stopped, isAvailable else { return }
        started = true
        self.defaultIsChromium = defaultIsChromium
        self.pagesPending = pagesPending
        self.pagesSpare = pagesSpare
        self.placement = placement
        // Whenever no spare window is ready (taken, or a tab started Chromium itself), an idle
        // task makes one, so a new Chromium tab joins a live window (CEFSpareWindow, PL-cef-tab).
        if placement.keepsSpareWindows { engine.onSpareWindowNeeded = { [weak self] in self?.spareNeeded() } }
        post(.launch)
    }

    /// No spare Chromium window is ready: an idle task makes one (one queued spare step serves
    /// every request before it runs; it reads the spare state then).
    private func spareNeeded() {
        guard !stopped, placement.keepsSpareWindows, allowsSpare, engine.isRunning, !spareWaitsForPages else { return }
        post(.spare)
    }

    /// A Chromium tab is likely soon: map the framework now and post `CefInitialize` once it
    /// loaded. Once per process.
    public func chromiumLikely(_ reason: Reason) {
        guard self.reason == nil, isAvailable, !engine.isRunning, !stopped else { return }
        self.reason = reason
        engine.preload()
        // The step is posted once the framework is mapped, so CefInitialize never waits on a
        // cold load and then lands in input.
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        // main-hop-allow: only awaits the framework load CEFEngine runs off main; its resume posts the idle step
        Task { [weak self] in
            await self?.engine.libraryLoadEnded()
            self?.post(.initialize)
        }
    }

    /// Starts Chromium now, with no idle wait: with the Chromium Host its start holds the main thread only for
    /// the shim calls (the attach and the start's disk reads run off main; placed by ``ChromiumHostLaunchSlot``,
    /// p08-startup-046). Once per process, as ``chromiumLikely(_:)``; the first spare window, where the placement keeps
    /// one, is still an idle step.
    public func startWithoutIdleWait(_ reason: Reason) {
        guard self.reason == nil, isAvailable, !engine.isRunning, !stopped else { return }
        self.reason = reason
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        // main-hop-allow: CefInitialize is main-thread by Chromium's contract (architecture.md 5a); the Host's attach and disk reads run off main (ChromiumHostLaunchSlot)
        Task { [weak self] in
            await self?.engine.warmStart(reason: reason.rawValue)
            self?.warmStarted()
        }
    }

    /// Whether cmux pages keep a Chromium spare changed (`pagesSpare`, read again now): kept, an
    /// idle task builds the pages spare; no longer kept (pages left Chromium), the untaken pages
    /// spare closes now. Nothing to do before Chromium runs: the first spare step reads
    /// `pagesSpare` itself.
    public func pagesSpareChanged() {
        guard !stopped, placement.keepsSpareWindows, engine.isRunning else { return }
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
        due = [:]
        afterMenu = []
        afterQuiet = []
        menuEnd = nil
        quietEnd = nil
    }

    /// Takes back pending `step`: its posted idle task does nothing when it runs, and a menu or
    /// quiet wait that only it needed ends now.
    private func cancel(_ step: Step) {
        pending.remove(step)
        due[step] = nil
        afterMenu.removeAll { $0 == step }
        afterQuiet.removeAll { $0 == step }
        if afterMenu.isEmpty { menuEnd = nil }
        if afterQuiet.isEmpty { quietEnd = nil }
    }

    /// Takes `step` unless it is pending (the pending one runs the same step later), and queues it
    /// once startup settled.
    private func post(_ step: Step) {
        guard !stopped, !pending.contains(step) else { return }
        pending.insert(step)
        idle.whenStartupSettled { [weak self] in self?.queue(step) }
    }

    /// Posts pending `step`'s idle task with what is left of its `maxDelay` (its first queue sets
    /// the end).
    private func queue(_ step: Step) {
        guard !stopped, pending.contains(step) else { return }
        let now = idle.uptime
        let end = due[step] ?? now + maxDelay(step)
        due[step] = end
        idle.postIdleStep(owner: step.owner, maxDelay: max(.zero, end - now), file: #fileID, line: #line) { [weak self] slot in
            self?.run(step, in: slot)
        }
    }

    private func maxDelay(_ step: Step) -> Duration {
        step == .spare ? policy.spareMaxDelay : policy.warmStartMaxDelay
    }

    /// `step`'s idle task runs. While a menu tracks it waits for the menu to close; a step that
    /// holds the main thread waits for the rest of the input quiet, and for a slot that may run
    /// past its deadline. Internal, not private: tests run the posted steps through their fake.
    func run(_ step: Step, in slot: ChromiumWarmupSlot) {
        guard !stopped, pending.contains(step) else { return }
        if isTrackingMenu() { return waitForMenu(step) }
        if step.holdsMainThread(placement) {
            let quietLeft = inputQuietLeft()
            if quietLeft > .zero { return waitForQuiet(step, quietLeft) }
            guard slot.mayOverrun else { return queue(step) }
        }
        pending.remove(step)
        due[step] = nil
        switch step {
        case .launch: launchCheck()
        case .initialize: initialize()
        case .spare: prepareSpare()
        }
    }

    /// The rest of ``Policy/inputQuiet`` after the person's last dispatched input; zero or less
    /// once it passed, or before any input.
    private func inputQuietLeft() -> Duration {
        guard let last = input.lastDispatched?.timestamp else { return .zero }
        return policy.inputQuiet - (idle.uptime - .seconds(last))
    }

    /// The launch step: while new browser tabs open in Chromium, any browser tab is a Chromium
    /// tab, so Chromium starts now and no Cmd-Shift-L pays CefInitialize; otherwise a recent
    /// Chromium user gets the framework mapped.
    private func launchCheck() {
        if defaultIsChromium() { return chromiumLikely(.launch) }
        // task-owner: one launch check per process; reads one small file off the main thread
        // main-hop-allow: only awaits CEFEngine's off-main use record read; its resume maps the framework (preload, off main)
        Task { [weak self] in
            guard let self, await engine.usedRecently(within: policy.recentUse), !stopped else { return }
            engine.preload()
        }
    }

    /// The `CefInitialize` step: it runs in this idle task's own turn (the slot that may overrun,
    /// after the input quiet), not in a later continuation that no scheduler picked
    /// (`ChromiumWarmupEngine.initializeLoaded`, p08-startup-018). The step is posted only once the
    /// load ended (``chromiumLikely(_:)``), so no await is left. Chromium that a tab started
    /// meanwhile goes on to the spare.
    private func initialize() {
        guard let reason, !engine.isRunning else { return warmStarted() }
        engine.initializeLoaded(reason: reason.rawValue)
        warmStarted()
    }

    /// Chromium runs: the next missing spare window (CEFSpareWindow, the default profile's, then
    /// the pages profile's) is an idle step of its own, so neither step lands in the first tab's
    /// or page's open. None where the placement keeps no spare window (`chromiumHostNoSpareWindow`).
    private func warmStarted() {
        guard !stopped, placement.keepsSpareWindows, allowsSpare, engine.isRunning else { return }
        post(.spare)
    }

    private func prepareSpare() {
        guard allowsSpare, engine.isRunning else { return }
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
            queue(step)
        }
    }

    /// `step` came `left` before the input quiet ends: it stays pending, and one deadline at the
    /// end of the quiet posts it again (with the other steps that came meanwhile). Input after
    /// that makes the step wait again when it runs.
    private func waitForQuiet(_ step: Step, _ left: Duration) {
        if !afterQuiet.contains(step) { afterQuiet.append(step) }
        guard quietEnd == nil else { return }
        quietEnd = idle.after(left, owner: "ChromiumWarmup.quiet") { [weak self] in self?.quietEnded() }
    }

    private func quietEnded() {
        quietEnd = nil
        let steps = afterQuiet
        afterQuiet = []
        for step in steps {
            queue(step)
        }
    }
}

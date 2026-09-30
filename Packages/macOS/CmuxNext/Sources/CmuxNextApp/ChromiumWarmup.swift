import AppKit
import CmuxNextBrowser
import CmuxNextWakeups

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// - A few seconds after launch the framework is mapped on a background
///   thread (`CEFEngine.preload`, no Chromium code runs).
/// - When a Chromium tab is likely, `CefInitialize` runs at the next idle
///   moment: no key or mouse input to this app for `Policy.idleInput` and no
///   menu tracking, waited for with one-shot deadlines (a deadline re-arms
///   for the rest of the quiet period after input, and the end of menu
///   tracking re-arms it; nothing polls). Likely means a Chromium tab in any window (restored or
///   not), the "+" menu, the palette's Chromium entries, and while Chromium
///   is the default engine (`browser.defaultEngine`) also any browser tab in
///   any window, the palette's default browser entries (New Browser Tab,
///   Split Browser, New Browser Workspace), or switching the default to
///   Chromium. Otherwise CEF stays lazy: a user who never browses never pays
///   for it (AppServices+Chromium).
@MainActor
final class ChromiumWarmup {
    enum Reason: String, Sendable {
        case restoredTab
        case newTabMenu
        case palette
        /// A browser tab exists and new ones default to Chromium.
        case browserTab
        /// The default engine was just switched to Chromium.
        case defaultEngine
    }

    struct Policy: Sendable {
        var launchPreloadDelay: Duration = .seconds(3)
        var idleInput: Duration = .milliseconds(750)
        /// Give up (stay lazy) when the app never goes idle this long.
        var maxWait: Duration = .seconds(60)
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
    private(set) var reason: Reason?

    init(
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

    /// Maps the framework `launchPreloadDelay` after launch.
    func start() {
        guard !launchTimer.isScheduled, isAvailable else { return }
        launchTimer.schedule(after: policy.launchPreloadDelay) { @MainActor [weak self] in
            self?.engine.preload()
        }
    }

    /// A Chromium tab is likely soon: map the framework now and run
    /// `CefInitialize` at the next idle moment. Once per process.
    func chromiumLikely(_ reason: Reason) {
        guard self.reason == nil, isAvailable, !engine.isRunning else { return }
        self.reason = reason
        engine.preload()
        lastInput = now()
        waiting = true
        installInputMonitor()
        armIdle(after: policy.idleInput)
        giveUpTimer.schedule(after: policy.maxWait) { @MainActor [weak self] in self?.finishWaiting() }
    }

    func stop() {
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
                MainActor.assumeIsolated {
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
        guard let reason else { return }
        finishWaiting()
        // task-owner: one warm start per process; CEFEngine owns its lifetime
        Task { await engine.warmStart(reason: reason.rawValue) }
    }

    /// True when no input reached this app for `idleInput` and no menu is
    /// tracking.
    func isIdle(_ policy: Policy) -> Bool {
        guard !isTrackingMenu() else { return false }
        let quiet = now() - lastInput
        return quiet >= policy.idleInput.inSeconds
    }

    /// Records input while a warm start waits (no monitor otherwise).
    func noteInput() { lastInput = now() }

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

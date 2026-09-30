import AppKit
import CmuxNextBrowser

/// Starts Chromium before the first Chromium tab needs it, so its two
/// unavoidable main-thread steps (`CefInitialize` and the first Chromium
/// window, about 80-160 ms each; architecture.md 5a, the one allowed
/// exception) do not land in the middle of user input.
///
/// - A few seconds after launch the framework is mapped on a background
///   thread (`CEFEngine.preload`, no Chromium code runs).
/// - When a Chromium tab is likely, `CefInitialize` runs at the next idle
///   moment: no key or mouse input to this app for `Policy.idleInput` and no
///   menu tracking. Likely means a Chromium tab in any window (restored or
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
        var poll: Duration = .milliseconds(250)
        /// Give up (stay lazy) when the app never goes idle this long.
        var maxWait: Duration = .seconds(60)
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let engine: CEFEngine
    private let policy: Policy
    private let sleep: Sleep
    private let now: @MainActor () -> TimeInterval
    private let isTrackingMenu: @MainActor () -> Bool
    private var launchTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var inputMonitor: Any?
    private var lastInput: TimeInterval = 0
    private(set) var reason: Reason?

    init(
        engine: CEFEngine,
        policy: Policy = Policy(),
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isTrackingMenu: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking }
    ) {
        self.engine = engine
        self.policy = policy
        self.sleep = sleep
        self.now = now
        self.isTrackingMenu = isTrackingMenu
    }

    private var isAvailable: Bool { engine.availability == .available }

    /// Maps the framework `launchPreloadDelay` after launch.
    func start() {
        guard launchTask == nil, isAvailable else { return }
        let delay = policy.launchPreloadDelay
        launchTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
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
        installInputMonitor()
        let policy = policy
        warmTask = Task { [weak self, sleep] in
            var waited: Duration = .zero
            while let self, !self.isIdle(policy) {
                if waited >= policy.maxWait { self.finishWaiting(); return }
                do { try await sleep(policy.poll) } catch { return }
                waited += policy.poll
            }
            guard let self else { return }
            self.finishWaiting()
            await self.engine.warmStart(reason: reason.rawValue)
        }
    }

    func stop() {
        launchTask?.cancel()
        warmTask?.cancel()
        finishWaiting()
    }

    /// True when no input reached this app for `idleInput` and no menu is
    /// tracking.
    func isIdle(_ policy: Policy) -> Bool {
        guard !isTrackingMenu() else { return false }
        let quiet = now() - lastInput
        return quiet >= Double(policy.idleInput.components.seconds)
            + Double(policy.idleInput.components.attoseconds) / 1e18
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
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }
}

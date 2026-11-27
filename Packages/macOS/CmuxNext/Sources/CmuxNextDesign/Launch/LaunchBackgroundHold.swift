import AppKit
public import CmuxNextWakeups

/// Leo (CMUX-629): "the other portions need to draw / technically only need to draw that one workspace open and the
/// sidebar / relaunches". At launch only the open workspace and the sidebar are made; what nobody sees waits until
/// they are live, then runs at idle as before.
///
/// It holds the app's budgeted background work (``MainFrameBudget/holdBackgroundForLaunch()``: the next Cmd-N's
/// reserved workspace and its panes, the pane spare, the binding table and New Tab action warm-ups, the New Tab
/// spare's refills) and the hidden page spares that start on their own timers (``whenReleased(_:)``: the New Tab
/// spare page, the page host pool's spare). It releases at the launch settle (the app's `LaunchSettle`: the first
/// window frame is committed and the first live terminal frame came, or a pane region is ready any other way, or the
/// daemon is unavailable), and at the latest ``backstop`` after the first window frame, whatever happens (a launch
/// that never settles). A person's key or click before then ends it at once (``noteInput()``): what their action
/// needs is made in its own turn, as when no spare was ready, and nothing waits behind the hold. Nothing is dropped:
/// queued work runs from the next frame on, in the order it was queued.
///
/// ```swift
/// let hold = LaunchBackgroundHold(budget: mainWork.budget)   // before anything queues background work
/// hold.install(settled: launchSettle.whenSettled, firstFrame: firstFrame)
/// hold.whenReleased { services.startHiddenPageSpares() }
/// ```
@MainActor
public final class LaunchBackgroundHold {
    /// The longest the hold lasts after the first window frame.
    public static let backstop: Duration = .seconds(4)

    private let budget: MainFrameBudget
    private let timer: DemandTimer
    private let mark: @MainActor (String) -> Void
    public private(set) var isReleased = false
    private var waiters: [@MainActor () -> Void] = []
    private var inputMonitor: Any?

    /// Holds `budget`'s background work from now on.
    ///
    /// - Parameters:
    ///   - timer: The backstop's timer (tests inject a manual clock).
    ///   - mark: Records the release as a launch mark (`launch.background_released`, or `..._by_backstop`).
    public init(budget: MainFrameBudget, timer: DemandTimer = DemandTimer(owner: "LaunchBackgroundHold.backstop"),
                mark: @escaping @MainActor (String) -> Void = { _ in }) {
        self.budget = budget
        self.timer = timer
        self.mark = mark
        budget.holdBackgroundForLaunch()
    }

    /// Releases when `settled` runs its work (the launch settle), at a person's first key or click, or ``backstop``
    /// after `firstFrame` opens.
    public func install(settled: @MainActor (@escaping @MainActor () -> Void) -> Void, firstFrame: FirstFrameGate) {
        settled { [weak self] in self?.release() }
        firstFrame.whenOpen { [weak self] in
            guard let self, !isReleased else { return }
            timer.schedule(after: Self.backstop) { @MainActor [weak self] in self?.release(byBackstop: true) }
        }
        guard !isReleased else { return } // `settled` ran its work at once
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.noteInput()
            return event
        }
    }

    /// A person's key or click: the hold ends before the event is handled, so their action never waits behind it.
    public func noteInput() {
        release(reason: "input")
    }

    /// Runs `work` once released (at once after).
    public func whenReleased(_ work: @escaping @MainActor () -> Void) {
        if isReleased { work() } else { waiters.append(work) }
    }

    /// Ends the hold (first call only) and runs the waiting work in order (after the event's frame, on input).
    public func release(byBackstop: Bool = false) {
        release(reason: byBackstop ? "backstop" : nil)
    }

    private func release(reason: String?) {
        guard !isReleased else { return }
        isReleased = true
        timer.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        budget.releaseLaunchHold()
        mark(reason.map { "launch.background_released_by_\($0)" } ?? "launch.background_released")
        let waiting = waiters
        waiters.removeAll()
        // On input, after the frame the person's event commits: nothing more runs in their turn.
        if reason == "input" { AfterFrameCommit().run { for work in waiting { work() } } } else { for work in waiting { work() } }
    }
}

import CmuxNextWakeups

/// The deadline of one tab's media roll call (`CEFMediaBridge`, `BrowserMediaFrames`): after a frame
/// detached, the frames that did not answer within ``limit`` are dropped.
///
/// One bounded deadline on an injected clock (tests pass a manual one), never a poll. A new roll call
/// replaces a pending one; a new document's commit and the browser's end cancel it (`cancel()`). A
/// frame that answers after the deadline is not lost: its report adds its entry again
/// (`BrowserMediaFrames.apply`).
@MainActor
final class CEFMediaRollCall {
    /// How long a roll call waits for the frames' answers.
    let limit: Duration
    private let deadline: DemandTimer

    /// - Parameters:
    ///   - limit: The answer window (``BrowserMediaState/rollCallDeadline`` by default).
    ///   - clock: Times the deadline; the default is the continuous clock, tests pass a manual one.
    init(limit: Duration = BrowserMediaState.rollCallDeadline, clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        deadline = DemandTimer(owner: "CEFMediaBridge.rollCall", clock: clock)
    }

    /// True while a roll call waits for its deadline.
    var isPending: Bool { deadline.isScheduled }

    /// Starts the deadline (replacing a pending one); `onEnd` runs once when it passes.
    func start(onEnd: @escaping @MainActor () -> Void) {
        // A bounded, cancellable deadline: the answers come within it, a gone frame never does.
        deadline.schedule(after: limit) { @MainActor in onEnd() }
    }

    /// Ends the pending roll call without dropping anything (a new document, the browser's end).
    func cancel() {
        deadline.cancel()
    }
}

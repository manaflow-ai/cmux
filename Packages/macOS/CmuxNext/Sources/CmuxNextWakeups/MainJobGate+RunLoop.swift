import AppKit
import CmuxNextCompat

/// The main run loop's side of a ``MainJobGate``: what the word says about input
/// is refreshed each turn, held jobs drain after each commit, the one-refresh deadline releases
/// them, and a nested run loop releases them at its entry and suspends holding until it exits.
///
/// - After each wait, the pending kinds are published to the word (``InputPendingState/publish(_:)``),
///   so an off-main job enqueued while the main thread sleeps is held only when input really waits.
/// - Every release runs after a commit stage (``AfterFrameCommit/everyPass(_:)``: after Core
///   Animation's commit, at `beforeWaiting` and at the run loop's `exit`, so a pass that never
///   waits still has one), never before the pass's commit of the input: past the deadline every
///   held job goes in order; otherwise, with no input pending, the oldest one goes, so it runs and
///   commits before the next (the input check between jobs).
/// - While jobs stay held, a one-shot wake is armed for the hold's deadline (``DeadlineWake``), so
///   the deadline holds in an idle app too: input that is never dispatched (a key a system hotkey
///   took) does not keep the FIFO until unrelated work wakes the main thread.
/// - A menu's tracking loop or a modal session (`NSEventTrackingRunLoopMode`, `NSModalPanelRunLoopMode`)
///   releases the FIFO at its entry, and nothing is held until its exit: such a loop runs
///   main-actor jobs while it tracks, and holding them there would stall the menu.
///
/// ```swift
/// let loop = MainJobGateRunLoop(gate: gate, pending: pending, wakeUps: mainWork.wakeUps)
/// ```
@MainActor
public final class MainJobGateRunLoop {
    /// Wakes the main run loop once, `delay` from now, so a pass reaches its commit stage at the
    /// hold's deadline; the returned closure cancels the wake.
    public typealias DeadlineWake = @MainActor (_ delay: Duration) -> @MainActor () -> Void

    private let gate: MainJobGate
    private let kinds: @MainActor () -> SessionInputPending.Kinds
    private let inputPending: @MainActor () -> Bool
    private let refreshNanos: @MainActor () -> UInt64
    private let wakeAtDeadline: DeadlineWake
    private var observers: [MainRunLoopObserver] = []
    /// The hold whose deadline wake is armed, and its cancel.
    private var armed: (hold: UInt64, cancel: @MainActor () -> Void)?
    /// Nested tracking or modal loops entered and not exited.
    private var nestedDepth = 0

    /// The modes whose loops release the FIFO and suspend holding.
    static let nestedModes: [CFRunLoopMode] = [
        CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString),
        CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString),
    ]

    /// The app's: the session's pending input, its display's refresh and the main thread's
    /// deadline queue (`MainWorkScheduler.wakeUps`) for the deadline wake.
    public convenience init(gate: MainJobGate, pending: SessionInputPending, wakeUps: MainWakeUpQueue) {
        self.init(gate: gate, kinds: { pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime) },
                  inputPending: { pending.hasPendingInput(uptime: ProcessInfo.processInfo.systemUptime) },
                  refreshNanos: { UInt64(pending.refreshInterval * 1e9) },
                  wakeAtDeadline: Self.wake(on: wakeUps))
    }

    /// - Parameters:
    ///   - gate: The gate it drains.
    ///   - kinds: The input pending now, published to the word each turn.
    ///   - inputPending: Whether input is pending now: the check between held jobs.
    ///   - refreshNanos: The display's refresh interval: the deadline after the first held job.
    ///   - wakeAtDeadline: Arms the one-shot wake for a hold's deadline.
    ///   - commit: The commit seam the drain runs after.
    init(gate: MainJobGate, kinds: @escaping @MainActor () -> SessionInputPending.Kinds,
         inputPending: @escaping @MainActor () -> Bool, refreshNanos: @escaping @MainActor () -> UInt64,
         wakeAtDeadline: @escaping DeadlineWake, commit: AfterFrameCommit = AfterFrameCommit()) {
        self.gate = gate
        self.kinds = kinds
        self.inputPending = inputPending
        self.refreshNanos = refreshNanos
        self.wakeAtDeadline = wakeAtDeadline
        observers.append(MainRunLoopObserver(activities: .afterWaiting, order: .min) { [weak self] _ in
            self?.turnStarted()
        })
        observers.append(commit.everyPass { [weak self] in self?.drainAfterCommit() ?? false })
        for mode in Self.nestedModes {
            observers.append(MainRunLoopObserver(activities: [.entry, .exit], order: .min, mode: mode) { [weak self] activity in
                if activity == .entry { self?.nestedLoopEntered() } else { self?.nestedLoopExited() }
            })
        }
    }

    /// A deadline wake on `queue`: a precise entry whose fire only wakes the main run loop; the
    /// pass it starts reaches the commit stage, where the drain releases the overdue FIFO.
    static func wake(on queue: MainWakeUpQueue) -> DeadlineWake {
        { delay in
            let token = queue.insert(owner: "MainJobGate.deadline", after: delay, policy: .precise) {}
            return { _ = queue.cancel(token) }
        }
    }

    /// Stops observing the run loop (also on release) and drops an armed deadline wake.
    public func invalidate() {
        observers.forEach { $0.invalidate() }
        observers = []
        disarm()
    }

    // MARK: Stages (internal: tests drive them)

    /// The turn's start, after the wait: the input pending now.
    func turnStarted() {
        gate.state.publish(kinds())
    }

    /// After the pass's commit: the deadline, else the oldest held job when no input is pending,
    /// else the deadline wake. Then pending kinds the pass dispatched are cleared before the wait.
    /// True when it forwarded a job.
    func drainAfterCommit() -> Bool {
        defer { if !gate.state.bits.isDisjoint(with: .kinds) { gate.state.publish(kinds()) } }
        guard gate.state.bits.contains(.held) else {
            disarm()
            return false
        }
        let refresh = refreshNanos()
        if gate.releaseIfOverdue(refreshNanos: refresh) {
            disarm()
            return true
        }
        if !inputPending(), gate.forwardOldest() { return true }
        arm(refreshNanos: refresh)
        return false
    }

    func nestedLoopEntered() {
        nestedDepth += 1
        guard nestedDepth == 1 else { return }
        gate.enterNestedLoop()
    }

    func nestedLoopExited() {
        guard nestedDepth > 0 else { return }
        nestedDepth -= 1
        if nestedDepth == 0 { gate.exitNestedLoop() }
    }

    /// Arms the wake for the current hold's deadline, once per hold.
    private func arm(refreshNanos: UInt64) {
        guard let deadline = gate.deadline(refreshNanos: refreshNanos), armed?.hold != deadline.hold else { return }
        disarm()
        armed = (deadline.hold, wakeAtDeadline(.nanoseconds(Int64(clamping: deadline.remaining))))
    }

    private func disarm() {
        armed?.cancel()
        armed = nil
    }
}

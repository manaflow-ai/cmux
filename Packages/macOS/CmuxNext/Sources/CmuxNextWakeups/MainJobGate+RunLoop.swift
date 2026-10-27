import AppKit
import CmuxNextCompat

/// The main run loop's side of a ``MainJobGate`` (p04-input-076): what the word says about input
/// is refreshed each turn, held jobs drain after each commit, the one-refresh deadline releases
/// them, and a nested run loop releases them at its entry and suspends holding until it exits.
///
/// - Each turn (after the wait) and before each wait, the pending kinds are published to the word
///   (``InputPendingState/publish(_:)``), so an off-main job enqueued while the main thread sleeps
///   is held only when input really waits.
/// - After each pass's commit (``AfterFrameCommit/everyPass(_:)``, after Core Animation's commit):
///   past the deadline every held job goes in order; otherwise, with no input pending, the oldest
///   one goes, so it runs and commits before the next (the input check between jobs).
/// - Before each pass's timers, the deadline is checked too: a pass that never waits (the run loop
///   polls while sources keep firing) has no commit stage.
/// - A menu's tracking loop or a modal session (`NSEventTrackingRunLoopMode`, `NSModalPanelRunLoopMode`)
///   releases the FIFO at its entry, and nothing is held until its exit: such a loop runs
///   main-actor jobs while it tracks, and holding them there would stall the menu.
///
/// ```swift
/// let loop = MainJobGateRunLoop(gate: gate, pending: pending)
/// ```
@MainActor
public final class MainJobGateRunLoop {
    private let gate: MainJobGate
    private let kinds: @MainActor () -> SessionInputPending.Kinds
    private let inputPending: @MainActor () -> Bool
    private let refreshNanos: @MainActor () -> UInt64
    private var observers: [MainRunLoopObserver] = []
    /// Nested tracking or modal loops entered and not exited.
    private var nestedDepth = 0

    /// The modes whose loops release the FIFO and suspend holding.
    static let nestedModes: [CFRunLoopMode] = [
        CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString),
        CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString),
    ]

    /// The app's: the session's pending input and its display's refresh.
    public convenience init(gate: MainJobGate, pending: SessionInputPending) {
        self.init(gate: gate, kinds: { pending.pendingKinds(uptime: ProcessInfo.processInfo.systemUptime) },
                  inputPending: { pending.hasPendingInput(uptime: ProcessInfo.processInfo.systemUptime) },
                  refreshNanos: { UInt64(pending.refreshInterval * 1e9) })
    }

    /// - Parameters:
    ///   - gate: The gate it drains.
    ///   - kinds: The input pending now, published to the word each turn.
    ///   - inputPending: Whether input is pending now: the check between held jobs.
    ///   - refreshNanos: The display's refresh interval: the deadline after the first held job.
    ///   - commit: The commit seam the drain runs after.
    init(gate: MainJobGate, kinds: @escaping @MainActor () -> SessionInputPending.Kinds,
         inputPending: @escaping @MainActor () -> Bool, refreshNanos: @escaping @MainActor () -> UInt64,
         commit: AfterFrameCommit = AfterFrameCommit()) {
        self.gate = gate
        self.kinds = kinds
        self.inputPending = inputPending
        self.refreshNanos = refreshNanos
        observers.append(MainRunLoopObserver(activities: [.afterWaiting, .beforeTimers], order: .min) { [weak self] activity in
            self?.turn(activity)
        })
        observers.append(commit.everyPass { [weak self] in self?.drainAfterCommit() ?? false })
        for mode in Self.nestedModes {
            observers.append(MainRunLoopObserver(activities: [.entry, .exit], order: .min, mode: mode) { [weak self] activity in
                if activity == .entry { self?.nestedLoopEntered() } else { self?.nestedLoopExited() }
            })
        }
    }

    /// Stops observing the run loop (also on release).
    public func invalidate() {
        observers.forEach { $0.invalidate() }
        observers = []
    }

    // MARK: Stages (internal: tests drive them)

    /// The turn's start: the input after the wait, and the deadline before the timers.
    func turn(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting { gate.state.publish(kinds()) }
        guard gate.state.bits.contains(.held) else { return }
        gate.releaseIfOverdue(refreshNanos: refreshNanos())
    }

    /// After the pass's commit: the deadline, else the oldest held job when no input is pending.
    /// Then pending kinds the pass dispatched are cleared before the wait. True when it forwarded a job.
    func drainAfterCommit() -> Bool {
        defer { if !gate.state.bits.isDisjoint(with: .kinds) { gate.state.publish(kinds()) } }
        guard gate.state.bits.contains(.held) else { return false }
        if gate.releaseIfOverdue(refreshNanos: refreshNanos()) { return true }
        guard !inputPending() else { return false }
        return gate.forwardOldest()
    }

    func nestedLoopEntered() {
        nestedDepth += 1
        guard nestedDepth == 1 else { return }
        gate.state.insert(.nestedLoop)
        gate.releaseAll(.nestedLoop)
    }

    func nestedLoopExited() {
        guard nestedDepth > 0 else { return }
        nestedDepth -= 1
        if nestedDepth == 0 { gate.state.remove(.nestedLoop) }
    }
}

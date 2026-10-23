/// Runs one action once after the current main-actor turn, however many times it was asked for in
/// that turn: a burst of changes (a switch that hides N pages and moves N panes) does the work once,
/// with every change applied, and never on the turn that shows them. Event-driven: one task per
/// burst, none while idle; it records no wakeup in the ledger (it is the tail of the turn's own work).
///
/// ```swift
/// private(set) lazy var replanAfterTurn = AfterTurn { [weak self] in self?.replan() }
/// func tabDidHide(_ key: String) { hiddenAt[key] = .now; replanAfterTurn.schedule() }
/// ```
@MainActor
public final class AfterTurn {
    private let action: @MainActor () -> Void
    /// The queued run's generation; nil when none is queued.
    private var queued: UInt64?
    private var generation: UInt64 = 0

    /// - Parameter action: The work to run after the turn (called on the main actor).
    public init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// True while a run is queued for after this turn.
    public var isScheduled: Bool { queued != nil }

    /// Queues one run after this turn; a no-op while one is queued.
    public func schedule() {
        guard queued == nil else { return }
        generation &+= 1
        let mine = generation
        queued = mine
        // task-owner: this coalescer (weak); one per burst, ends after one run. Detached: not under the
        // task-locals (an action run's scope) of whichever change came first.
        Task.detached { @MainActor [weak self] in
            guard let self, self.queued == mine else { return }
            self.queued = nil
            self.action()
        }
    }

    /// Drops a queued run (the owner did the work directly).
    public func cancel() { queued = nil }
}

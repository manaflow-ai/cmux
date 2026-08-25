internal import CmuxFoundation

/// Applies one shared terminal configuration snapshot without monopolizing the
/// main actor for the full surface registry.
@MainActor
public final class TerminalConfigurationApplyScheduler<ID: Hashable, Snapshot> {
    /// A unit of main-actor work scheduled for a later executor turn.
    public typealias ScheduledAction = @MainActor @Sendable () -> Void

    /// The scheduling seam used to yield between bounded drain turns.
    public typealias Scheduler =
        @MainActor @Sendable (@escaping ScheduledAction) -> Void

    /// Describes one bounded pull from a fixed traversal snapshot.
    public enum NextIDResult {
        /// A live identity is ready to apply.
        case id(ID)

        /// One released or otherwise skipped registration was consumed.
        case skipped

        /// The fixed traversal has reached its endpoint.
        case exhausted
    }

    /// Pulls one bounded visit from a fixed traversal snapshot.
    public typealias NextID = @MainActor () -> NextIDResult

    /// Applies the shared snapshot to one currently live surface identity.
    public typealias Apply =
        @MainActor (ID, Snapshot) -> TerminalConfigurationApplyResult

    /// Rolls back surface-specific state that cannot finish applying.
    public typealias Abandon =
        @MainActor (ID, Snapshot, TerminalConfigurationApplyAbandonReason) -> Void

    /// Runs after the active traversal reaches its fixed endpoint.
    public typealias Completion = @MainActor @Sendable () -> Void

    private let maximumVisitsPerDrain: Int
    private let maximumAttemptsPerID: Int
    private let schedule: Scheduler

    private var snapshot: Snapshot?
    private var prioritizedIDs: [ID] = []
    private var prioritizedIndex = 0
    private var nextID: NextID?
    private var apply: Apply?
    private var abandon: Abandon?
    private var completion: Completion?
    private var visitedIDs: Set<ID> = []
    private var retryIDs: [ID] = []
    private var retryIndex = 0
    private var attemptCounts: [ID: Int] = [:]
    private var sourceIsExhausted = false
    private var isDrainScheduled = false

    /// Creates a scheduler with explicit per-turn work limits.
    ///
    /// Up to `maximumVisitsPerDrain` focused or visible identities supplied to
    /// ``replacePendingWork(snapshot:prioritizedIDs:nextID:apply:abandon:completion:)``
    /// are applied in the accepting turn. Remaining identities, including
    /// skipped traversal entries, are visited through later main-actor turns.
    ///
    /// - Parameters:
    ///   - maximumVisitsPerDrain: Maximum traversal visits in one scheduled
    ///     turn, including duplicates and skipped entries.
    ///   - maximumAttemptsPerID: Maximum attempts before `abandon` runs.
    ///   - schedule: Scheduling seam. The default yields to a later main-actor
    ///     executor turn through ``MainActorDeferredActionScheduler``.
    public init(
        maximumVisitsPerDrain: Int,
        maximumAttemptsPerID: Int = 3,
        schedule: Scheduler? = nil
    ) {
        precondition(maximumVisitsPerDrain > 0)
        precondition(maximumAttemptsPerID > 0)
        self.maximumVisitsPerDrain = maximumVisitsPerDrain
        self.maximumAttemptsPerID = maximumAttemptsPerID
        if let schedule {
            self.schedule = schedule
        } else {
            let deferredScheduler = MainActorDeferredActionScheduler()
            self.schedule = { action in
                deferredScheduler.schedule(zeroDelayPolicy: .yieldOnce) {
                    action()
                }
            }
        }
    }

    /// Replaces any undrained work with one newer configuration snapshot.
    ///
    /// A previously scheduled turn is reused instead of scheduling another one.
    /// The old traversal, snapshot, and completion are discarded, making stale
    /// surface application unrepresentable after a newer reload is accepted.
    ///
    /// - Parameters:
    ///   - snapshot: Immutable configuration-derived state shared by every apply.
    ///   - prioritizedIDs: Focused and visible identities in application order.
    ///   - nextID: Pull-based fixed traversal for all remaining identities.
    ///     Return ``NextIDResult/skipped`` for a consumed dead entry and
    ///     ``NextIDResult/exhausted`` only at the traversal endpoint.
    ///   - apply: Applies `snapshot` to a currently live identity.
    ///   - abandon: Rolls back surface-specific state after retry exhaustion or
    ///     replacement by a newer snapshot.
    ///   - completion: Runs only if this snapshot reaches the traversal endpoint
    ///     before being superseded.
    public func replacePendingWork(
        snapshot: Snapshot,
        prioritizedIDs: [ID],
        nextID: @escaping NextID,
        apply: @escaping Apply,
        abandon: @escaping Abandon = { _, _, _ in },
        completion: @escaping Completion = {}
    ) {
        abandonPendingRetriesBeforeReplacement()
        self.snapshot = snapshot
        self.prioritizedIDs = prioritizedIDs
        prioritizedIndex = 0
        self.nextID = nextID
        self.apply = apply
        self.abandon = abandon
        self.completion = completion
        visitedIDs.removeAll(keepingCapacity: true)
        retryIDs.removeAll(keepingCapacity: true)
        retryIndex = 0
        attemptCounts.removeAll(keepingCapacity: true)
        sourceIsExhausted = false

        drainImmediatePriority()
        scheduleDrain()
    }

    private func drainImmediatePriority() {
        guard let snapshot, let apply else { return }
        var visits = 0
        while prioritizedIndex < prioritizedIDs.count,
              visits < maximumVisitsPerDrain {
            let id = prioritizedIDs[prioritizedIndex]
            prioritizedIndex += 1
            visits += 1
            guard visitedIDs.insert(id).inserted else { continue }
            attempt(id, snapshot: snapshot, apply: apply)
        }
    }

    private func abandonPendingRetriesBeforeReplacement() {
        guard let snapshot, let abandon,
              retryIndex < retryIDs.count else {
            return
        }
        var abandonedIDs: Set<ID> = []
        for id in retryIDs[retryIndex...]
        where abandonedIDs.insert(id).inserted {
            abandon(id, snapshot, .pendingWorkReplaced)
        }
    }

    private func scheduleDrain() {
        guard snapshot != nil, !isDrainScheduled else { return }
        isDrainScheduled = true
        schedule { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        isDrainScheduled = false
        guard let snapshot, let apply else { return }

        var visits = 0
        while visits < maximumVisitsPerDrain {
            if prioritizedIndex < prioritizedIDs.count {
                let id = prioritizedIDs[prioritizedIndex]
                prioritizedIndex += 1
                visits += 1
                guard visitedIDs.insert(id).inserted else { continue }
                attempt(id, snapshot: snapshot, apply: apply)
                continue
            }

            if !sourceIsExhausted {
                switch nextID?() ?? .exhausted {
                case .id(let id):
                    visits += 1
                    guard visitedIDs.insert(id).inserted else { continue }
                    attempt(id, snapshot: snapshot, apply: apply)
                case .skipped:
                    visits += 1
                case .exhausted:
                    sourceIsExhausted = true
                }
                continue
            }

            if retryIndex < retryIDs.count {
                let id = retryIDs[retryIndex]
                retryIndex += 1
                visits += 1
                attempt(id, snapshot: snapshot, apply: apply)
                continue
            }

            finish()
            return
        }
        scheduleDrain()
    }

    private func attempt(
        _ id: ID,
        snapshot: Snapshot,
        apply: Apply
    ) {
        let attemptCount = (attemptCounts[id] ?? 0) + 1
        attemptCounts[id] = attemptCount
        switch apply(id, snapshot) {
        case .complete:
            attemptCounts.removeValue(forKey: id)
        case .retry where attemptCount < maximumAttemptsPerID:
            retryIDs.append(id)
        case .retry:
            abandon?(id, snapshot, .retryLimitReached)
            attemptCounts.removeValue(forKey: id)
        }
    }

    private func finish() {
        snapshot = nil
        prioritizedIDs = []
        prioritizedIndex = 0
        nextID = nil
        apply = nil
        abandon = nil
        visitedIDs.removeAll(keepingCapacity: true)
        retryIDs.removeAll(keepingCapacity: true)
        retryIndex = 0
        attemptCounts.removeAll(keepingCapacity: true)
        sourceIsExhausted = false
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}

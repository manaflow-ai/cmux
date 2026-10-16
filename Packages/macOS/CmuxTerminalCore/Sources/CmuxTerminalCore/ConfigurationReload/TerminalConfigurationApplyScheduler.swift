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
    public typealias NextIDResult = TerminalConfigurationApplyNextIDResult<ID>

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
    private var drainGeneration: UInt64 = 0
    private var workGeneration: UInt64 = 0

    /// Whether a snapshot still owns pending or scheduled surface work.
    public var hasPendingWork: Bool {
        snapshot != nil
    }

    /// Creates a scheduler with explicit per-turn work limits.
    ///
    /// Every focused or visible identity supplied to
    /// ``replacePendingWork(snapshot:prioritizedIDs:nextID:apply:abandon:completion:)``
    /// is applied in the accepting turn. `maximumVisitsPerDrain` bounds only
    /// the deferred registry traversal (including skipped entries), so visible
    /// panes repaint together while offscreen work yields to later turns.
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
    ///   - completion: Runs when this snapshot reaches the endpoint or is
    ///     explicitly canceled for a newer request.
    public func replacePendingWork(
        snapshot: Snapshot,
        prioritizedIDs: [ID],
        nextID: @escaping NextID,
        apply: @escaping Apply,
        abandon: @escaping Abandon = { _, _, _ in },
        completion: @escaping Completion = {}
    ) {
        workGeneration &+= 1
        let replacementGeneration = workGeneration
        abandonPendingRetriesBeforeReplacement()
        guard workGeneration == replacementGeneration else { return }
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

    /// Cancels the active traversal and finishes its completion boundary.
    ///
    /// Already-applied identities are left intact; pending retry state is
    /// abandoned so a newer configuration can replace the snapshot without
    /// waiting for obsolete offscreen work.
    public func cancelPendingWork() {
        guard snapshot != nil else { return }
        workGeneration &+= 1
        let cancellationGeneration = workGeneration
        abandonPendingRetriesBeforeReplacement()
        guard workGeneration == cancellationGeneration else { return }
        drainGeneration &+= 1
        isDrainScheduled = false
        finish()
    }

    private func drainImmediatePriority() {
        guard let snapshot, let apply else { return }
        let generation = workGeneration
        while prioritizedIndex < prioritizedIDs.count {
            let id = prioritizedIDs[prioritizedIndex]
            prioritizedIndex += 1
            guard visitedIDs.insert(id).inserted else { continue }
            attempt(id, snapshot: snapshot, apply: apply)
            guard workGeneration == generation else { return }
        }
    }

    private func abandonPendingRetriesBeforeReplacement() {
        guard let snapshot, let abandon,
              retryIndex < retryIDs.count else {
            return
        }
        let pendingRetryIDs = Array(retryIDs[retryIndex...])
        // Mark the range consumed before invoking user-owned callbacks. An
        // abandon callback may synchronously install replacement work; leaving
        // retryIndex unchanged would recursively abandon the same IDs.
        retryIndex = retryIDs.count
        var abandonedIDs: Set<ID> = []
        for id in pendingRetryIDs
        where abandonedIDs.insert(id).inserted {
            // Continue through the copied range even if the callback installs
            // replacement work. Each old surface still owns rollback state;
            // the caller's generation guard prevents this pass from touching
            // the replacement scheduler state.
            abandon(id, snapshot, .pendingWorkReplaced)
        }
    }

    private func scheduleDrain() {
        guard snapshot != nil, !isDrainScheduled else { return }
        isDrainScheduled = true
        drainGeneration &+= 1
        let scheduledGeneration = drainGeneration
        schedule { [weak self] in
            guard let self,
                  self.drainGeneration == scheduledGeneration else {
                return
            }
            self.drain()
        }
    }

    private func drain() {
        isDrainScheduled = false
        guard let snapshot, let apply else { return }
        let generation = workGeneration

        var visits = 0
        let retryEndIndex = retryIDs.count
        while visits < maximumVisitsPerDrain {
            if prioritizedIndex < prioritizedIDs.count {
                let id = prioritizedIDs[prioritizedIndex]
                prioritizedIndex += 1
                visits += 1
                guard visitedIDs.insert(id).inserted else { continue }
                attempt(id, snapshot: snapshot, apply: apply)
                guard workGeneration == generation else { return }
                continue
            }

            if retryIndex < retryEndIndex {
                let id = retryIDs[retryIndex]
                retryIndex += 1
                visits += 1
                attempt(id, snapshot: snapshot, apply: apply)
                guard workGeneration == generation else { return }
                continue
            }

            if !sourceIsExhausted {
                let nextResult = nextID?() ?? .exhausted
                guard workGeneration == generation else { return }
                switch nextResult {
                case .id(let id):
                    visits += 1
                    guard visitedIDs.insert(id).inserted else { continue }
                    attempt(id, snapshot: snapshot, apply: apply)
                    guard workGeneration == generation else { return }
                case .skipped:
                    visits += 1
                case .exhausted:
                    sourceIsExhausted = true
                }
                continue
            }

            // A retry appended by this turn must yield before it can run.
            if retryIndex < retryIDs.count {
                scheduleDrain()
                return
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
        let generation = workGeneration
        let attemptCount = (attemptCounts[id] ?? 0) + 1
        attemptCounts[id] = attemptCount
        let result = apply(id, snapshot)
        guard workGeneration == generation else { return }
        switch result {
        case .complete:
            attemptCounts.removeValue(forKey: id)
        case .retry where attemptCount < maximumAttemptsPerID:
            retryIDs.append(id)
        case .retry:
            abandon?(id, snapshot, .retryLimitReached)
            guard workGeneration == generation else { return }
            attemptCounts.removeValue(forKey: id)
        }
    }

    private func finish() {
        drainGeneration &+= 1
        isDrainScheduled = false
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

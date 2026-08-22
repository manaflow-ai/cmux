import Foundation

/// Applies one shared terminal configuration snapshot without monopolizing the
/// main actor for the full surface registry.
@MainActor
public final class TerminalConfigurationApplyScheduler<ID: Hashable, Snapshot> {
    /// A unit of main-actor work scheduled for a later executor turn.
    public typealias ScheduledAction = @MainActor @Sendable () -> Void

    /// The scheduling seam used to yield between bounded drain turns.
    public typealias Scheduler =
        @MainActor @Sendable (@escaping ScheduledAction) -> Void

    /// Pulls the next surface identity from a fixed traversal snapshot.
    public typealias NextID = @MainActor () -> ID?

    /// Applies the shared snapshot to one currently live surface identity.
    public typealias Apply =
        @MainActor (ID, Snapshot) -> TerminalConfigurationApplyResult

    /// Rolls back surface-specific state after retry exhaustion.
    public typealias Abandon = @MainActor (ID, Snapshot) -> Void

    /// Runs after the active traversal reaches its fixed endpoint.
    public typealias Completion = @MainActor @Sendable () -> Void

    private let maximumImmediatePriorityCount: Int
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
    /// The immediate limit should stay small: it exists for the focused surface
    /// and a bounded number of visible siblings. All other identities are
    /// visited through later main-actor turns.
    ///
    /// - Parameters:
    ///   - maximumImmediatePriorityCount: Maximum prioritized identities applied
    ///     synchronously when work is replaced. Zero defers every identity.
    ///   - maximumVisitsPerDrain: Maximum identities visited in one scheduled
    ///     turn, including duplicates that are skipped.
    ///   - maximumAttemptsPerID: Maximum attempts before `abandon` runs.
    ///   - schedule: Scheduling seam. The default uses the next common main
    ///     run-loop turn.
    public init(
        maximumImmediatePriorityCount: Int,
        maximumVisitsPerDrain: Int,
        maximumAttemptsPerID: Int = 3,
        schedule: Scheduler? = nil
    ) {
        precondition(maximumImmediatePriorityCount >= 0)
        precondition(maximumVisitsPerDrain > 0)
        precondition(maximumAttemptsPerID > 0)
        self.maximumImmediatePriorityCount =
            maximumImmediatePriorityCount
        self.maximumVisitsPerDrain = maximumVisitsPerDrain
        self.maximumAttemptsPerID = maximumAttemptsPerID
        self.schedule = schedule ?? { action in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
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
    ///   - apply: Applies `snapshot` to a currently live identity.
    ///   - abandon: Rolls back surface-specific state after retry exhaustion.
    ///   - completion: Runs only if this snapshot reaches the traversal endpoint
    ///     before being superseded.
    public func replacePendingWork(
        snapshot: Snapshot,
        prioritizedIDs: [ID],
        nextID: @escaping NextID,
        apply: @escaping Apply,
        abandon: @escaping Abandon = { _, _ in },
        completion: @escaping Completion = {}
    ) {
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
        while visits < maximumImmediatePriorityCount,
              prioritizedIndex < prioritizedIDs.count {
            let id = prioritizedIDs[prioritizedIndex]
            prioritizedIndex += 1
            visits += 1
            guard visitedIDs.insert(id).inserted else { continue }
            attempt(id, snapshot: snapshot, apply: apply)
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
            let id: ID
            let isRetry: Bool
            if prioritizedIndex < prioritizedIDs.count {
                id = prioritizedIDs[prioritizedIndex]
                prioritizedIndex += 1
                isRetry = false
            } else if !sourceIsExhausted,
                      let next = nextID?() {
                id = next
                isRetry = false
            } else if !sourceIsExhausted {
                sourceIsExhausted = true
                continue
            } else if retryIndex < retryIDs.count {
                id = retryIDs[retryIndex]
                retryIndex += 1
                isRetry = true
            } else {
                finish()
                return
            }
            visits += 1
            if !isRetry {
                guard visitedIDs.insert(id).inserted else { continue }
            }
            attempt(id, snapshot: snapshot, apply: apply)
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
            abandon?(id, snapshot)
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

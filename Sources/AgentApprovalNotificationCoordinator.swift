import Foundation

/// Settles native-agent approval signals before they become notifications.
///
/// Codex emits `PermissionRequest` before its own approval reviewer runs, so
/// the request is not proof that the user will ever need to act. This
/// coordinator holds correlated requests through the settle window, cancels
/// requests that resolve before delivery, and keeps at most one delivered
/// notification per pane while any correlated requests remain outstanding.
@MainActor
final class AgentApprovalNotificationCoordinator {
    typealias Action = @MainActor @Sendable () -> Void
    typealias Cancellation = @MainActor @Sendable () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping Action) -> Cancellation
    typealias ScheduledActionDispatcher = @MainActor (@escaping Action) -> Void

    struct Delivery: Equatable, Sendable {
        let workspaceID: UUID
        let surfaceID: UUID
        let title: String
        let subtitle: String
        let body: String
        /// Agent context is carried through delayed approval delivery so
        /// notification-policy hooks see the same category/pending metadata
        /// as they would for an immediate agent notification.
        let agent: TerminalNotificationPolicyAgentContext?
        let correlationKey: String
        /// Optional producer key supplied by the source notification. The
        /// coordinator still owns the episode key, while the queue keeps this
        /// alias so a producer can clear its exact notification.
        let producerCorrelationKey: String?
    }

    struct Clear: Equatable, Sendable {
        let workspaceID: UUID
        let surfaceID: UUID
        let correlationKey: String
    }

    private struct Candidate {
        let workspaceID: UUID
        let title: String
        let subtitle: String
        let body: String
        let approvalID: AgentApprovalCorrelationID
        let isDerived: Bool
        let agent: TerminalNotificationPolicyAgentContext?
        let producerCorrelationKey: String?
        let readyAt: TimeInterval
        let sequence: UInt64
    }

    private struct PaneState {
        var workspaceID: UUID
        /// Monotonic activity marker used to evict the least-recently-used
        /// pane when stale hook traffic exceeds the global registry bound.
        var lastTouchedAt: TimeInterval
        var lastTouchedSequence: UInt64
        // Key by the logical approval id so duplicate hook deliveries replace
        // one record instead of growing an unbounded sequence-keyed bag.
        var candidates: [String: Candidate] = [:]
        // A derived tuple identity can represent either a retried hook or two
        // distinct identical calls. Keep that ambiguity explicit so one exact
        // completion cannot settle more than one logical request.
        var ambiguousApprovalIDs: Set<String> = []
        var scheduledID: UUID?
        var scheduledAt: TimeInterval?
        var cancelScheduled: Cancellation?
        var deliveredCorrelationKey: String?
        var deliveredProducerCorrelationKey: String? = nil
        var deliveredApprovalID: String? = nil
        var cancelEpisodeExpiry: Cancellation?
        var episodeID: UUID?
    }

    private struct ResolutionKey: Hashable {
        let surfaceID: UUID
        let value: String
    }

    private let settleDelay: TimeInterval
    private let tombstoneLifetime: TimeInterval
    private let episodeLifetime: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let schedule: Scheduler
    private let dispatchScheduledAction: ScheduledActionDispatcher
    private let deliver: @MainActor (Delivery) -> Void
    private let clear: @MainActor (Clear) -> Void
    private static let maxCandidatesPerPane = 64
    /// A malformed or stale hook can name an arbitrary surface. Keep that
    /// untrusted fan-out bounded even when no live owner exists to cancel it.
    nonisolated static let maxTrackedPanes = 256
    /// Delivered episodes remain visible until an authoritative resolution or
    /// dismissal. This fallback only retires unresolved panes when the
    /// scheduler is unavailable.
    private static let unresolvedPaneLifetime: TimeInterval = 10 * 60
    private static let maxTombstonesPerKind = 1_024
    nonisolated static let defaultEpisodeLifetime: TimeInterval = .infinity
    nonisolated static let approvalCorrelationPrefix = "agent-approval:"
    private var panes: [UUID: PaneState] = [:]
    private var exactResolutionTombstones: [ResolutionKey: TimeInterval] = [:]
    private var scopeResolutionTombstones: [ResolutionKey: TimeInterval] = [:]
    private var nextSequence: UInt64 = 0

    init(
        settleDelay: TimeInterval = 0.1,
        tombstoneLifetime: TimeInterval = 1,
        episodeLifetime: TimeInterval = AgentApprovalNotificationCoordinator.defaultEpisodeLifetime,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = AgentApprovalNotificationCoordinator.scheduleOnMainActor(delay:action:),
        dispatchScheduledAction: @escaping ScheduledActionDispatcher,
        deliver: @escaping @MainActor (Delivery) -> Void,
        clear: @escaping @MainActor (Clear) -> Void
    ) {
        self.settleDelay = settleDelay.isFinite ? max(0, settleDelay) : 0.1
        self.tombstoneLifetime = tombstoneLifetime.isFinite ? max(0, tombstoneLifetime) : 1
        self.episodeLifetime = episodeLifetime.isFinite ? max(0, episodeLifetime) : .infinity
        self.now = now
        self.schedule = schedule
        self.dispatchScheduledAction = dispatchScheduledAction
        self.deliver = deliver
        self.clear = clear
    }

    func stage(
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        approvalID: AgentApprovalCorrelationID,
        isDerived: Bool = false,
        agent: TerminalNotificationPolicyAgentContext? = nil,
        producerCorrelationKey: String? = nil
    ) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        prunePanes(at: timestamp)
        let exactKey = ResolutionKey(surfaceID: surfaceID, value: approvalID.rawValue)
        guard exactResolutionTombstones[exactKey] == nil else { return }
        let scopeKey = ResolutionKey(surfaceID: surfaceID, value: approvalID.scope.rawValue)
        guard scopeResolutionTombstones[scopeKey] == nil else { return }

        nextSequence &+= 1
        let candidate = Candidate(
            workspaceID: workspaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            approvalID: approvalID,
            isDerived: isDerived,
            agent: agent,
            producerCorrelationKey: producerCorrelationKey,
            readyAt: timestamp + settleDelay,
            sequence: nextSequence
        )
        var state = panes[surfaceID] ?? PaneState(
            workspaceID: workspaceID,
            lastTouchedAt: timestamp,
            lastTouchedSequence: nextSequence
        )
        state.workspaceID = workspaceID
        state.lastTouchedAt = timestamp
        state.lastTouchedSequence = nextSequence
        if let existing = state.candidates[approvalID.rawValue] {
            // Preserve the original deadline/order for a duplicate signal;
            // only the latest display text may have changed. If no provider
            // discriminator exists, an exact completion is intentionally
            // treated as ambiguous and waits for a scope-level resolution.
            if isDerived || existing.isDerived {
                state.ambiguousApprovalIDs.insert(approvalID.rawValue)
            }
            state.candidates[approvalID.rawValue] = Candidate(
                workspaceID: candidate.workspaceID,
                title: candidate.title,
                subtitle: candidate.subtitle,
                body: candidate.body,
                approvalID: candidate.approvalID,
                isDerived: candidate.isDerived,
                agent: candidate.agent,
                producerCorrelationKey: candidate.producerCorrelationKey,
                readyAt: min(existing.readyAt, candidate.readyAt),
                sequence: existing.sequence
            )
        } else {
            state.candidates[approvalID.rawValue] = candidate
        }
        if state.candidates.count > Self.maxCandidatesPerPane {
            let overflow = state.candidates.count - Self.maxCandidatesPerPane
            let staleIDs = state.candidates.values
                .sorted { $0.sequence < $1.sequence }
                // Never evict the candidate represented by the visible
                // banner. It remains in `candidates` until its exact or scope
                // resolution arrives, so dropping it here would make later
                // unrelated resolutions clear the wrong episode.
                .filter { $0.approvalID.rawValue != state.deliveredApprovalID }
                .prefix(overflow)
                .map { $0.approvalID.rawValue }
            for staleID in staleIDs {
                state.candidates.removeValue(forKey: staleID)
                state.ambiguousApprovalIDs.remove(staleID)
            }
        }
        panes[surfaceID] = state
        prunePanes(at: timestamp)

        // Once a pane has one visible approval notification, additional
        // requests join that pending episode without producing more banners.
        guard state.deliveredCorrelationKey == nil else { return }
        scheduleNextFlush(surfaceID: surfaceID, timestamp: timestamp)
    }

    func resolve(surfaceID: UUID, approvalID: AgentApprovalCorrelationID) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        prunePanes(at: timestamp)
        exactResolutionTombstones[
            ResolutionKey(surfaceID: surfaceID, value: approvalID.rawValue)
        ] = timestamp + tombstoneLifetime
        guard var state = panes[surfaceID] else { return }
        if state.ambiguousApprovalIDs.contains(approvalID.rawValue) {
            // The provider did not give us enough information to know which
            // identical request completed. Leave the candidate visible until
            // the authoritative turn/scope resolution arrives.
            panes[surfaceID] = state
            return
        }
        guard state.candidates.removeValue(forKey: approvalID.rawValue) != nil else { return }
        finishResolution(surfaceID: surfaceID, state: &state, timestamp: timestamp)
    }

    func resolve(surfaceID: UUID, approvalScope: AgentApprovalCorrelationID.Scope) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        prunePanes(at: timestamp)
        scopeResolutionTombstones[
            ResolutionKey(surfaceID: surfaceID, value: approvalScope.rawValue)
        ] = timestamp + tombstoneLifetime
        guard var state = panes[surfaceID] else { return }
        state.candidates = state.candidates.filter {
            $0.value.approvalID.scope != approvalScope
        }
        state.ambiguousApprovalIDs = state.ambiguousApprovalIDs.filter {
            state.candidates[$0] != nil
        }
        finishResolution(surfaceID: surfaceID, state: &state, timestamp: timestamp)
    }

    func cancel(surfaceID: UUID, clearDelivered: Bool = true) {
        guard let state = panes.removeValue(forKey: surfaceID) else { return }
        state.cancelScheduled?()
        state.cancelEpisodeExpiry?()
        if clearDelivered, let correlationKey = state.deliveredCorrelationKey {
            clear(Clear(
                workspaceID: state.workspaceID,
                surfaceID: surfaceID,
                correlationKey: correlationKey
            ))
        }
    }

    func cancel(workspaceID: UUID, clearDelivered: Bool = true) {
        cancelPanes(clearDelivered: clearDelivered) { claimedWorkspaceID, _ in
            claimedWorkspaceID == workspaceID
        }
    }

    func cancelPanes(
        clearDelivered: Bool = true,
        where shouldCancel: (_ claimedWorkspaceID: UUID, _ surfaceID: UUID) -> Bool
    ) {
        let surfaceIDs = panes.compactMap { surfaceID, state in
            shouldCancel(state.workspaceID, surfaceID) ? surfaceID : nil
        }
        for surfaceID in surfaceIDs {
            cancel(surfaceID: surfaceID, clearDelivered: clearDelivered)
        }
    }

    func cancelAll(clearDelivered: Bool = true) {
        for surfaceID in Array(panes.keys) {
            cancel(surfaceID: surfaceID, clearDelivered: clearDelivered)
        }
    }

    /// Indicates whether a surface still owns an approval episode. The
    /// mutation bus uses this at resolution boundaries to retire the surface
    /// generation when the last candidate is gone, fencing stale resolutions
    /// from a later episode that reuses the same surface id.
    func hasEpisode(surfaceID: UUID) -> Bool {
        panes[surfaceID] != nil
    }

    /// Keep a live approval episode attached to the surface's current owner.
    /// Candidates already carry their enqueue-time owner, so update them as a
    /// unit; otherwise a later resolution would clear the source workspace
    /// after the pane moved.
    func rebind(surfaceID: UUID, toWorkspaceID workspaceID: UUID) {
        guard var state = panes[surfaceID], state.workspaceID != workspaceID else { return }
        state.workspaceID = workspaceID
        state.lastTouchedAt = now()
        nextSequence &+= 1
        state.lastTouchedSequence = nextSequence
        state.candidates = state.candidates.mapValues { candidate in
            Candidate(
                workspaceID: workspaceID,
                title: candidate.title,
                subtitle: candidate.subtitle,
                body: candidate.body,
                approvalID: candidate.approvalID,
                isDerived: candidate.isDerived,
                agent: candidate.agent,
                producerCorrelationKey: candidate.producerCorrelationKey,
                readyAt: candidate.readyAt,
                sequence: candidate.sequence
            )
        }
        panes[surfaceID] = state
    }

    /// Removes a delivered approval episode after the user (or another
    /// notification path) dismissed its banner. This intentionally does not
    /// emit a second clear: the store has already removed the row. Pending
    /// candidates are discarded too, so a late staged hook cannot resurrect a
    /// banner the user explicitly dismissed.
    @discardableResult
    func dismissDelivered(correlationKey: String) -> UUID? {
        guard let match = panes.first(where: { $0.value.deliveredCorrelationKey == correlationKey }) else {
            return nil
        }
        let surfaceID = match.key
        let timestamp = now()
        pruneTombstones(at: timestamp)
        let state = panes.removeValue(forKey: surfaceID)
        state?.cancelScheduled?()
        state?.cancelEpisodeExpiry?()
        if let state {
            // A dismissed banner must not be recreated by a delayed duplicate
            // hook. Fence every approval that was part of the dismissed episode
            // for the same bounded tombstone window.
            let expiry = timestamp + tombstoneLifetime
            for candidate in state.candidates.values {
                exactResolutionTombstones[
                    ResolutionKey(surfaceID: surfaceID, value: candidate.approvalID.rawValue)
                ] = expiry
            }
        }
        return surfaceID
    }

    private func finishResolution(
        surfaceID: UUID,
        state: inout PaneState,
        timestamp: TimeInterval
    ) {
        guard !state.candidates.isEmpty else {
            state.cancelScheduled?()
            state.cancelEpisodeExpiry?()
            panes.removeValue(forKey: surfaceID)
            if let correlationKey = state.deliveredCorrelationKey {
                clear(Clear(
                    workspaceID: state.workspaceID,
                    surfaceID: surfaceID,
                    correlationKey: correlationKey
                ))
            }
            return
        }

        if let latest = state.candidates.values.max(by: { $0.sequence < $1.sequence }) {
            state.workspaceID = latest.workspaceID
        }
        let displayedApprovalResolved = state.deliveredCorrelationKey != nil
            && state.deliveredApprovalID.map { state.candidates[$0] == nil } == true
        let replacementClear: Clear?
        if displayedApprovalResolved, let deliveredCorrelationKey = state.deliveredCorrelationKey {
            replacementClear = Clear(
                workspaceID: state.workspaceID,
                surfaceID: surfaceID,
                correlationKey: deliveredCorrelationKey
            )
            state.deliveredCorrelationKey = nil
            state.deliveredProducerCorrelationKey = nil
            state.deliveredApprovalID = nil
            state.cancelEpisodeExpiry?()
            state.cancelEpisodeExpiry = nil
            state.episodeID = nil
        } else {
            replacementClear = nil
        }
        panes[surfaceID] = state
        if let replacementClear {
            clear(replacementClear)
            scheduleNextFlush(
                surfaceID: surfaceID,
                timestamp: timestamp,
                replacingExistingSchedule: true
            )
        } else if state.deliveredCorrelationKey == nil {
            scheduleNextFlush(
                surfaceID: surfaceID,
                timestamp: timestamp,
                replacingExistingSchedule: true
            )
        }
    }

    private func scheduleNextFlush(
        surfaceID: UUID,
        timestamp: TimeInterval,
        replacingExistingSchedule: Bool = false
    ) {
        guard var state = panes[surfaceID],
              state.deliveredCorrelationKey == nil,
              let deadline = state.candidates.values.map(\.readyAt).min() else {
            return
        }
        if !replacingExistingSchedule,
           let scheduledAt = state.scheduledAt,
           scheduledAt <= deadline {
            return
        }

        state.cancelScheduled?()
        let scheduledID = UUID()
        state.scheduledID = scheduledID
        state.scheduledAt = deadline
        state.cancelScheduled = nil
        panes[surfaceID] = state

        let cancellation = schedule(max(0, deadline - timestamp)) { [weak self] in
            guard let self else { return }
            self.dispatchScheduledAction { [weak self] in
                self?.flush(surfaceID: surfaceID, scheduledID: scheduledID)
            }
        }
        guard var current = panes[surfaceID], current.scheduledID == scheduledID else {
            cancellation()
            return
        }
        current.cancelScheduled = cancellation
        panes[surfaceID] = current
    }

    private func flush(surfaceID: UUID, scheduledID: UUID) {
        guard var state = panes[surfaceID],
              state.scheduledID == scheduledID,
              state.deliveredCorrelationKey == nil else {
            return
        }
        state.scheduledID = nil
        state.scheduledAt = nil
        state.cancelScheduled = nil
        panes[surfaceID] = state

        let timestamp = now()
        guard let candidate = state.candidates.values
            .filter({ $0.readyAt <= timestamp })
            .max(by: { $0.sequence < $1.sequence }) else {
            scheduleNextFlush(surfaceID: surfaceID, timestamp: timestamp)
            return
        }

        let correlationKey = Self.approvalCorrelationPrefix + UUID().uuidString
        state.workspaceID = candidate.workspaceID
        state.deliveredCorrelationKey = correlationKey
        state.deliveredProducerCorrelationKey = candidate.producerCorrelationKey
        state.deliveredApprovalID = candidate.approvalID.rawValue
        state.cancelEpisodeExpiry?()
        let episodeID = UUID()
        state.episodeID = episodeID
        let expiryCancellation: Cancellation?
        if episodeLifetime.isFinite, episodeLifetime > 0 {
            expiryCancellation = schedule(episodeLifetime) { [weak self] in
                guard let self else { return }
                self.dispatchScheduledAction { [weak self] in
                    self?.expireEpisode(surfaceID: surfaceID, correlationKey: correlationKey, episodeID: episodeID)
                }
            }
        } else {
            expiryCancellation = nil
        }
        // Store the cancellation only if this delivery is still current.
        // `deliver` may synchronously enqueue a clear on another lane.
        state.cancelEpisodeExpiry = expiryCancellation
        panes[surfaceID] = state
        deliver(Delivery(
            workspaceID: candidate.workspaceID,
            surfaceID: surfaceID,
            title: candidate.title,
            subtitle: candidate.subtitle,
            body: candidate.body,
            agent: candidate.agent,
            correlationKey: correlationKey,
            producerCorrelationKey: candidate.producerCorrelationKey
        ))
    }

    private func pruneTombstones(at timestamp: TimeInterval) {
        exactResolutionTombstones = exactResolutionTombstones.filter { $0.value > timestamp }
        scopeResolutionTombstones = scopeResolutionTombstones.filter { $0.value > timestamp }
        if exactResolutionTombstones.count > Self.maxTombstonesPerKind {
            exactResolutionTombstones = Dictionary(
                uniqueKeysWithValues: exactResolutionTombstones
                    .sorted { $0.value > $1.value }
                    .prefix(Self.maxTombstonesPerKind)
                    .map { ($0.key, $0.value) }
            )
        }
        if scopeResolutionTombstones.count > Self.maxTombstonesPerKind {
            scopeResolutionTombstones = Dictionary(
                uniqueKeysWithValues: scopeResolutionTombstones
                    .sorted { $0.value > $1.value }
                    .prefix(Self.maxTombstonesPerKind)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    /// Retires stale or least-recently-used pane episodes before untrusted hook
    /// traffic can grow the registry without limit. Evicted delivered episodes
    /// are explicitly cleared so the persisted notification cannot outlive its
    /// in-memory owner.
    private func prunePanes(at timestamp: TimeInterval) {
        if timestamp.isFinite {
            let staleIDs = panes.compactMap { surfaceID, state -> UUID? in
                guard state.deliveredCorrelationKey == nil,
                      state.lastTouchedAt.isFinite,
                      timestamp - state.lastTouchedAt >= Self.unresolvedPaneLifetime else {
                    return nil
                }
                return surfaceID
            }
            for surfaceID in staleIDs {
                cancel(surfaceID: surfaceID, clearDelivered: true)
            }
        }

        let overflow = panes.count - Self.maxTrackedPanes
        guard overflow > 0 else { return }
        let evictedIDs = panes
            .sorted { lhs, rhs in
                if lhs.value.lastTouchedSequence != rhs.value.lastTouchedSequence {
                    return lhs.value.lastTouchedSequence < rhs.value.lastTouchedSequence
                }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .prefix(overflow)
            .map(\.key)
        for surfaceID in evictedIDs {
            cancel(surfaceID: surfaceID, clearDelivered: true)
        }
    }

    private func expireEpisode(
        surfaceID: UUID,
        correlationKey: String,
        episodeID: UUID
    ) {
        guard var state = panes[surfaceID],
              state.deliveredCorrelationKey == correlationKey,
              state.episodeID == episodeID else { return }
        let timestamp = now()
        state.cancelEpisodeExpiry = nil
        state.episodeID = nil
        state.cancelScheduled?()
        state.cancelScheduled = nil
        guard !state.candidates.isEmpty else {
            panes.removeValue(forKey: surfaceID)
            clear(Clear(
                workspaceID: state.workspaceID,
                surfaceID: surfaceID,
                correlationKey: correlationKey
            ))
            return
        }

        // A finite episode lifetime is a recovery/re-notification deadline,
        // not permission to hide an approval that still awaits the user. Retire
        // the old persisted row, reset the episode, and deliver the outstanding
        // candidate again with a fresh correlation key.
        let previousClear = Clear(
            workspaceID: state.workspaceID,
            surfaceID: surfaceID,
            correlationKey: correlationKey
        )
        state.deliveredCorrelationKey = nil
        state.deliveredProducerCorrelationKey = nil
        state.lastTouchedAt = timestamp
        nextSequence &+= 1
        state.lastTouchedSequence = nextSequence
        panes[surfaceID] = state
        clear(previousClear)
        scheduleNextFlush(
            surfaceID: surfaceID,
            timestamp: timestamp,
            replacingExistingSchedule: true
        )
    }

    nonisolated static func isApprovalCorrelationKey(_ value: String?) -> Bool {
        value?.hasPrefix(approvalCorrelationPrefix) == true
    }

    private static func scheduleOnMainActor(
        delay: TimeInterval,
        action: @escaping Action
    ) -> Cancellation {
        let boundedDelay = delay.isFinite ? max(0, delay) : 0
        // This is a genuine one-shot presentation deadline, not a polling
        // sleep. A main-run-loop timer keeps cancellation explicit and lets the
        // coordinator remain entirely on MainActor; tests inject a virtual
        // scheduler instead of waiting on wall-clock time.
        let timer = Timer(timeInterval: boundedDelay, repeats: false) { _ in
            // The timer is registered on `RunLoop.main`, so its callback is
            // guaranteed to execute on MainActor. Tell Swift's isolation
            // checker about that Foundation callback boundary synchronously.
            MainActor.assumeIsolated {
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

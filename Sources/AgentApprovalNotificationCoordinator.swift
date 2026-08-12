import Foundation

/// Settles native-agent approval signals before they become notifications.
///
/// Codex emits `PermissionRequest` before its own approval reviewer runs, so
/// the request is not proof that the user will ever need to act. This
/// coordinator holds correlated requests briefly, cancels requests that
/// resolve during that window, and keeps at most one delivered notification
/// per pane while any correlated requests remain outstanding.
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
        let correlationKey: String
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
        let readyAt: TimeInterval
        let sequence: UInt64
    }

    private struct PaneState {
        var workspaceID: UUID
        var candidates: [UInt64: Candidate] = [:]
        var scheduledID: UUID?
        var scheduledAt: TimeInterval?
        var cancelScheduled: Cancellation?
        var deliveredCorrelationKey: String?
    }

    private struct ResolutionKey: Hashable {
        let surfaceID: UUID
        let value: String
    }

    private let settleDelay: TimeInterval
    private let tombstoneLifetime: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let schedule: Scheduler
    private let dispatchScheduledAction: ScheduledActionDispatcher
    private let deliver: @MainActor (Delivery) -> Void
    private let clear: @MainActor (Clear) -> Void
    private var panes: [UUID: PaneState] = [:]
    private var exactResolutionTombstones: [ResolutionKey: [TimeInterval]] = [:]
    private var scopeResolutionTombstones: [ResolutionKey: TimeInterval] = [:]
    private var nextSequence: UInt64 = 0

    init(
        settleDelay: TimeInterval = 0.1,
        tombstoneLifetime: TimeInterval = 1,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = AgentApprovalNotificationCoordinator.scheduleOnMainActor(delay:action:),
        dispatchScheduledAction: @escaping ScheduledActionDispatcher,
        deliver: @escaping @MainActor (Delivery) -> Void,
        clear: @escaping @MainActor (Clear) -> Void
    ) {
        self.settleDelay = settleDelay.isFinite ? max(0, settleDelay) : 0.1
        self.tombstoneLifetime = tombstoneLifetime.isFinite ? max(0, tombstoneLifetime) : 1
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
        approvalID: AgentApprovalCorrelationID
    ) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        let exactKey = ResolutionKey(surfaceID: surfaceID, value: approvalID.rawValue)
        if consumeExactResolutionTombstone(for: exactKey) {
            return
        }
        let scopeKey = ResolutionKey(surfaceID: surfaceID, value: approvalID.scope.rawValue)
        guard scopeResolutionTombstones[scopeKey] == nil else { return }

        nextSequence &+= 1
        let candidate = Candidate(
            workspaceID: workspaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            approvalID: approvalID,
            readyAt: timestamp + settleDelay,
            sequence: nextSequence
        )
        var state = panes[surfaceID] ?? PaneState(workspaceID: workspaceID)
        state.workspaceID = workspaceID
        state.candidates[candidate.sequence] = candidate
        panes[surfaceID] = state

        // Once a pane has one visible approval notification, additional
        // requests join that pending episode without producing more banners.
        guard state.deliveredCorrelationKey == nil else { return }
        scheduleNextFlush(surfaceID: surfaceID, timestamp: timestamp)
    }

    func resolve(surfaceID: UUID, approvalID: AgentApprovalCorrelationID) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        guard var state = panes[surfaceID],
              let candidate = state.candidates.values
                  .filter({ $0.approvalID == approvalID })
                  .min(by: { $0.sequence < $1.sequence }) else {
            exactResolutionTombstones[
                ResolutionKey(surfaceID: surfaceID, value: approvalID.rawValue),
                default: []
            ].append(timestamp + tombstoneLifetime)
            return
        }
        state.candidates.removeValue(forKey: candidate.sequence)
        finishResolution(surfaceID: surfaceID, state: &state, timestamp: timestamp)
    }

    func resolve(surfaceID: UUID, approvalScope: AgentApprovalCorrelationID.Scope) {
        let timestamp = now()
        pruneTombstones(at: timestamp)
        scopeResolutionTombstones[
            ResolutionKey(surfaceID: surfaceID, value: approvalScope.rawValue)
        ] = timestamp + tombstoneLifetime
        guard var state = panes[surfaceID] else { return }
        state.candidates = state.candidates.filter {
            $0.value.approvalID.scope != approvalScope
        }
        finishResolution(surfaceID: surfaceID, state: &state, timestamp: timestamp)
    }

    func cancel(surfaceID: UUID, clearDelivered: Bool = true) {
        guard let state = panes.removeValue(forKey: surfaceID) else { return }
        state.cancelScheduled?()
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

    private func finishResolution(
        surfaceID: UUID,
        state: inout PaneState,
        timestamp: TimeInterval
    ) {
        guard !state.candidates.isEmpty else {
            state.cancelScheduled?()
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
        panes[surfaceID] = state
        guard state.deliveredCorrelationKey == nil else { return }
        scheduleNextFlush(
            surfaceID: surfaceID,
            timestamp: timestamp,
            replacingExistingSchedule: true
        )
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

        let correlationKey = "agent-approval:\(UUID().uuidString)"
        state.workspaceID = candidate.workspaceID
        state.deliveredCorrelationKey = correlationKey
        panes[surfaceID] = state
        deliver(Delivery(
            workspaceID: candidate.workspaceID,
            surfaceID: surfaceID,
            title: candidate.title,
            subtitle: candidate.subtitle,
            body: candidate.body,
            correlationKey: correlationKey
        ))
    }

    private func consumeExactResolutionTombstone(for key: ResolutionKey) -> Bool {
        guard var expirations = exactResolutionTombstones[key], !expirations.isEmpty else {
            return false
        }
        expirations.removeFirst()
        if expirations.isEmpty {
            exactResolutionTombstones.removeValue(forKey: key)
        } else {
            exactResolutionTombstones[key] = expirations
        }
        return true
    }

    private func pruneTombstones(at timestamp: TimeInterval) {
        exactResolutionTombstones = exactResolutionTombstones.compactMapValues { expirations in
            let liveExpirations = expirations.filter { $0 > timestamp }
            return liveExpirations.isEmpty ? nil : liveExpirations
        }
        scopeResolutionTombstones = scopeResolutionTombstones.filter { $0.value > timestamp }
    }

    private static func scheduleOnMainActor(
        delay: TimeInterval,
        action: @escaping Action
    ) -> Cancellation {
        let maximumDelay = TimeInterval(Int64.max / 1_000_000_000)
        let boundedDelay = delay.isFinite ? min(max(0, delay), maximumDelay) : 0
        // This cancellable deadline is the intended settle behavior, and tests
        // replace the scheduler rather than sleeping for synchronization.
        let task = Task { @MainActor in
            do {
                try await Task<Never, Never>.sleep(for: .seconds(boundedDelay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}

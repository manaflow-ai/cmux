import CmuxRemoteSession
import CmuxNotifications
import CmuxSettings
import Foundation

fileprivate struct QueuedTerminalNotificationKey: Hashable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
}

fileprivate struct QueuedAgentApprovalStage {
    let workspaceID: UUID
    let surfaceID: UUID
    let title: String
    let subtitle: String
    let body: String
    let approvalID: AgentApprovalCorrelationID
    let approvalIDIsDerived: Bool
    let agent: TerminalNotificationPolicyAgentContext?
}

fileprivate struct AgentApprovalMutationToken {
    let global: UInt64
    let workspace: UInt64
    let surface: UInt64
    let workspaceID: UUID?
    let surfaceID: UUID?
}

fileprivate struct QueuedTerminalNotification: Sendable {
    let key: QueuedTerminalNotificationKey
    let title: String
    let subtitle: String
    let body: String
    let replyShape: TerminalNotificationReplyShape
    let agent: TerminalNotificationPolicyAgentContext?
    let soundContext: NotificationSoundOverrideContext?
    let correlationKey: String?
}

fileprivate enum TerminalSocketMutation {
    case deliverNotification(QueuedTerminalNotification)
    case clearAllNotifications(through: UInt64)
    case clearNotificationsForTab(UUID, through: UInt64)
    case clearNotificationsForSurface(UUID, UUID, through: UInt64)
    case clearNotificationsForCorrelation(UUID, UUID, String, through: UInt64)
    case clearNotificationCorrelation(QueuedTerminalNotificationKey, String)
    case stageAgentApproval(QueuedAgentApprovalStage, AgentApprovalMutationToken)
    case resolveAgentApproval(UUID, AgentApprovalCorrelationID, AgentApprovalMutationToken)
    case resolveAgentApprovalScope(UUID, AgentApprovalCorrelationID.Scope, AgentApprovalMutationToken)
    case perform(@MainActor () -> Void)
}

fileprivate struct TerminalSocketMutationEntry {
    let sequence: UInt64
    let mutation: TerminalSocketMutation
    let notificationGeneration: UInt64?
    let notificationCoalescingKey: TerminalNotificationCoalescingKey?
    let performReplaceKey: TerminalMutationReplaceKey?
}

/// Identity for last-write-wins `.perform` mutations: a fresh enqueue removes
/// the pending same-key entry, bounding `pending` at one entry per key even
/// while the main actor is blocked and cannot drain. Shell activity is keyed
/// by logical surface; caller-supplied process generations are admission data,
/// never an extra queue dimension.
enum TerminalMutationReplaceKey: Hashable, Sendable {
    enum ScopedKind: Hashable, Sendable {
        case gitBranch, directory
        case portsKick(PortScanKickReason)
    }

    /// Shell reports follow a live surface across workspace and Dock moves, so
    /// their queue identity is the globally stable surface id alone.
    case shellActivity(surfaceId: UUID)
    /// Metadata whose mutation closure still resolves the claimed workspace.
    case scoped(tabId: UUID, surfaceId: UUID, kind: ScopedKind)
}

fileprivate struct TerminalNotificationCoalescingKey: Hashable {
    let generation: UInt64
    let notificationKey: QueuedTerminalNotificationKey
}

final class TerminalMutationBus: @unchecked Sendable {
    static let shared = TerminalMutationBus()

    private let lock = NSLock()
    private var pending: [TerminalSocketMutationEntry] = []
    private var drainScheduled = false
    private var nextSequence: UInt64 = 0
    private var currentNotificationGeneration: UInt64 = 0
    private var approvalGlobalGeneration: UInt64 = 0
    private var approvalWorkspaceGenerations: [UUID: UInt64] = [:]
    private var approvalSurfaceGenerations: [UUID: UInt64] = [:]
    private var approvalWorkspaceBySurface: [UUID: UUID] = [:]
    private var pendingApprovalMutationCount = 0
    // Hook traffic can outlive the workspaces/surfaces that produced it. Keep
    // generation fencing bounded even if a long-running process churns through
    // thousands of UUIDs. When the cap is reached, a global epoch bump safely
    // invalidates every outstanding token before the old key tables are reset.
    private let maxApprovalGenerationEntries = 4_096
    /// Bound approval-only traffic while the main actor is unavailable. Stage
    /// mutations are explicitly droppable; resolution mutations evict the
    /// oldest stage first so a stale approval cannot outlive a newer clear.
    private let maxPendingApprovalMutations = 256
    private let maxMutationsPerDrain = 16
#if DEBUG
    private var drainsSuspendedForTesting = false
#endif

    @MainActor
    private lazy var agentApprovalNotifications = AgentApprovalNotificationCoordinator(
        dispatchScheduledAction: { [weak self] action in
            self?.enqueueMainActorMutation(action)
        },
        deliver: { [weak self] delivery in
            self?.enqueueNotification(
                tabId: delivery.workspaceID,
                surfaceId: delivery.surfaceID,
                title: delivery.title,
                subtitle: delivery.subtitle,
                body: delivery.body,
                replyShape: .none,
                agent: delivery.agent,
                correlationKey: delivery.correlationKey,
                // The coordinator already owns approval coalescing. Preserve
                // unrelated notifications that are queued for the same pane.
                coalesces: false
            )
        },
        clear: { [weak self] clear in
            self?.enqueueClearNotification(
                tabId: clear.workspaceID,
                surfaceId: clear.surfaceID,
                correlationKey: clear.correlationKey
            )
        }
    )

    nonisolated func enqueueNotification(
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        replyShape: TerminalNotificationReplyShape = .none,
        agent: TerminalNotificationPolicyAgentContext? = nil,
        soundContext: NotificationSoundOverrideContext? = nil,
        correlationKey: String? = nil,
        coalesces: Bool = true
    ) {
        enqueueNotification(QueuedTerminalNotification(
            key: QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            title: title,
            subtitle: subtitle,
            body: body,
            replyShape: replyShape,
            agent: agent,
            soundContext: soundContext,
            correlationKey: correlationKey
        ), coalesces: coalesces)
    }

    /// User-facing removal paths must also retire the in-memory approval
    /// episode. Otherwise a later queued stage can recreate a banner that was
    /// already dismissed from the notification store.
    @MainActor
    func dismissAgentApproval(
        correlationKey: String,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil
    ) {
        guard AgentApprovalNotificationCoordinator.isApprovalCorrelationKey(correlationKey) else { return }
        let dismissedSurfaceID = agentApprovalNotifications.dismissDelivered(correlationKey: correlationKey)
        let resolvedSurfaceID = surfaceID ?? dismissedSurfaceID
        lock.lock()
        ensureApprovalGenerationCapacityLocked(workspaceID: workspaceID, surfaceID: resolvedSurfaceID)
        let resolvedWorkspaceID = workspaceID ?? resolvedSurfaceID.flatMap { approvalWorkspaceBySurface[$0] }
        if let resolvedWorkspaceID {
            approvalWorkspaceGenerations[resolvedWorkspaceID, default: 0] &+= 1
        }
        if let resolvedSurfaceID {
            approvalSurfaceGenerations[resolvedSurfaceID, default: 0] &+= 1
            approvalWorkspaceBySurface.removeValue(forKey: resolvedSurfaceID)
        }
        lock.unlock()
    }

    @MainActor
    func cancelAgentApproval(surfaceID: UUID) {
        agentApprovalNotifications.cancel(surfaceID: surfaceID, clearDelivered: false)
        invalidateApprovalGenerations(global: false, workspaceID: nil, surfaceID: surfaceID)
    }

    @MainActor
    func cancelAgentApprovals(workspaceID: UUID) {
        agentApprovalNotifications.cancel(workspaceID: workspaceID, clearDelivered: false)
        lock.lock()
        ensureApprovalGenerationCapacityLocked(workspaceID: workspaceID, surfaceID: nil)
        approvalWorkspaceGenerations[workspaceID, default: 0] &+= 1
        let surfaceIDs = approvalWorkspaceBySurface.compactMap { surfaceID, ownerID in
            ownerID == workspaceID ? surfaceID : nil
        }
        for surfaceID in surfaceIDs {
            approvalSurfaceGenerations[surfaceID, default: 0] &+= 1
            approvalWorkspaceBySurface.removeValue(forKey: surfaceID)
        }
        lock.unlock()
    }

    /// Rebind an approval episode when its terminal surface moves between
    /// workspaces. The move fences queued mutations captured under the old
    /// owner and updates the coordinator's eventual clear target.
    @MainActor
    func rebindAgentApproval(
        surfaceID: UUID,
        fromWorkspaceID: UUID,
        toWorkspaceID: UUID
    ) {
        guard fromWorkspaceID != toWorkspaceID else { return }
        agentApprovalNotifications.rebind(
            surfaceID: surfaceID,
            toWorkspaceID: toWorkspaceID
        )
        lock.lock()
        ensureApprovalGenerationCapacityLocked(
            workspaceID: toWorkspaceID,
            surfaceID: surfaceID
        )
        if let previousWorkspaceID = approvalWorkspaceBySurface[surfaceID],
           previousWorkspaceID != toWorkspaceID {
            approvalWorkspaceGenerations[previousWorkspaceID, default: 0] &+= 1
        }
        approvalWorkspaceBySurface[surfaceID] = toWorkspaceID
        lock.unlock()
    }

    nonisolated func enqueueAgentApprovalNotification(
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        subtitle: String,
        body: String,
        approvalID: AgentApprovalCorrelationID,
        approvalIDIsDerived: Bool = false,
        agent: TerminalNotificationPolicyAgentContext? = nil
    ) {
        lock.lock()
        ensureApprovalGenerationCapacityLocked(workspaceID: tabId, surfaceID: surfaceId)
        // A surface move (or a recycled surface identity) must fence stages
        // captured under its previous workspace, even before the next hook
        // arrives with the new workspace id.
        if let previousWorkspaceID = approvalWorkspaceBySurface[surfaceId],
           previousWorkspaceID != tabId {
            approvalWorkspaceGenerations[previousWorkspaceID, default: 0] &+= 1
        } else if approvalWorkspaceBySurface[surfaceId] == nil {
            // A retired surface identity may be reused for a new episode.
            // Advance its generation before capturing the new stage token so
            // a resolution that observed the retired mapping cannot settle
            // this replacement episode.
            approvalSurfaceGenerations[surfaceId, default: 0] &+= 1
        }
        approvalWorkspaceBySurface[surfaceId] = tabId
        let token = approvalMutationToken(workspaceID: tabId, surfaceID: surfaceId)
        lock.unlock()
        enqueueApprovalMutation(.stageAgentApproval(QueuedAgentApprovalStage(
            workspaceID: tabId,
            surfaceID: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            approvalID: approvalID,
            approvalIDIsDerived: approvalIDIsDerived,
            agent: agent
        ), token))
    }

    nonisolated func enqueueAgentApprovalResolution(
        surfaceId: UUID,
        approvalID: AgentApprovalCorrelationID
    ) {
        lock.lock()
        let token = approvalMutationToken(
            workspaceID: nil,
            surfaceID: surfaceId,
            capturesWorkspace: false
        )
        lock.unlock()
        enqueueApprovalMutation(.resolveAgentApproval(surfaceId, approvalID, token))
    }

    nonisolated func enqueueAgentApprovalResolution(
        surfaceId: UUID,
        approvalScope: AgentApprovalCorrelationID.Scope
    ) {
        lock.lock()
        let token = approvalMutationToken(
            workspaceID: nil,
            surfaceID: surfaceId,
            capturesWorkspace: false
        )
        lock.unlock()
        enqueueApprovalMutation(.resolveAgentApprovalScope(surfaceId, approvalScope, token))
    }

    nonisolated func enqueueClearAllNotifications() {
        invalidateApprovalGenerations(global: true, workspaceID: nil, surfaceID: nil)
        enqueueClear({ .clearAllNotifications(through: $0) }) { _ in true }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID) {
        // Surface-addressed entries may have moved since enqueue. Keep them
        // ahead of the barrier so delivery can resolve their live owner first.
        invalidateApprovalGenerations(global: false, workspaceID: tabId, surfaceID: nil)
        enqueueClear({ .clearNotificationsForTab(tabId, through: $0) }) { notification in
            notification.key.tabId == tabId && notification.key.surfaceId == nil
        }
    }

    nonisolated func enqueueClearNotifications(forTabId tabId: UUID, surfaceId: UUID) {
        // Canonical surface identity: a stale-keyed entry would retarget here at drain.
        invalidateApprovalGenerations(global: false, workspaceID: tabId, surfaceID: surfaceId)
        enqueueClear({ .clearNotificationsForSurface(tabId, surfaceId, through: $0) }) { notification in
            notification.key.surfaceId == surfaceId
        }
    }

    /// Clears one surface notification by its opaque producer correlation
    /// key. The key is part of the pending entry, so this removes only the
    /// request being reconciled even when a newer notification is queued on
    /// the same surface.
    nonisolated func enqueueClearNotifications(
        forTabId tabId: UUID,
        surfaceId: UUID,
        correlationKey: String
    ) {
        enqueueClear({
            .clearNotificationsForCorrelation(tabId, surfaceId, correlationKey, through: $0)
        }) { notification in
            notification.key.surfaceId == surfaceId
                && notification.correlationKey == correlationKey
        }
    }

    private nonisolated func enqueueClearNotification(
        tabId: UUID,
        surfaceId: UUID,
        correlationKey: String
    ) {
        // This is a correlation-only reconciliation emitted by the approval
        // coordinator. Do not advance pane generations here: a newer approval
        // stage already queued behind this clear must remain admissible. The
        // coordinator records its own exact tombstone before this mutation is
        // enqueued, so a late duplicate is still fenced without invalidating
        // unrelated stages.
        enqueueBarrierMutation(.clearNotificationCorrelation(
            QueuedTerminalNotificationKey(tabId: tabId, surfaceId: surfaceId),
            correlationKey
        ))
    }

    nonisolated func enqueueMainActorMutation(_ mutation: @escaping @MainActor () -> Void) {
        enqueueBarrierMutation(.perform(mutation))
    }

    nonisolated func markNotificationClearBoundary() -> UInt64 {
        lock.lock()
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        lock.unlock()
        return boundary
    }

    nonisolated func notificationGenerationSnapshot() -> UInt64 { lock.withLock { currentNotificationGeneration } }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, through boundary: UInt64) {
        discardPendingNotifications { notification, generation in
            notification.key.tabId == tabId && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID, through boundary: UInt64) {
        discardPendingNotifications { notification, generation in
            notification.key.tabId == tabId
                && notification.key.surfaceId == surfaceId
                && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications(
        forSurfaceId surfaceId: UUID,
        correlationKey: String,
        through boundary: UInt64
    ) {
        discardPendingNotifications { notification, generation in
            notification.key.surfaceId == surfaceId
                && notification.correlationKey == correlationKey
                && generation <= boundary
        }
    }

    nonisolated func discardPendingNotifications() {
        discardPendingNotifications(advanceGeneration: true) { _, _ in true }
        invalidateApprovalGenerations(global: true, workspaceID: nil, surfaceID: nil)
    }

    /// Direct store clears bypass the socket mutation cases, so cancel their
    /// staged approval state before discarding queued notification deliveries.
    @MainActor
    func discardPendingNotificationsForClearAll() {
        agentApprovalNotifications.cancelAll(clearDelivered: false)
        discardPendingNotifications()
    }

    nonisolated func discardPendingNotifications(forTabId tabId: UUID) {
        invalidateApprovalGenerations(global: false, workspaceID: tabId, surfaceID: nil)
        discardPendingNotifications { notification, _ in
            notification.key.tabId == tabId
        }
    }

    /// Exact enqueue-key discard. Use for source-scoped operations like
    /// `rebindSurfaceNotifications`, where a surface-wide discard could drop a
    /// newer entry legitimately queued under the destination key mid-move.
    nonisolated func discardPendingNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        invalidateApprovalGenerations(global: false, workspaceID: tabId, surfaceID: surfaceId)
        discardPendingNotifications { notification, _ in
            notification.key.tabId == tabId && notification.key.surfaceId == surfaceId
        }
    }

    /// Canonical-identity discard for clears and supersedes: pending entries
    /// are keyed by their enqueue-time (claimed) workspace but DELIVER to the
    /// surface's live owner (#7939), so a clear that matched only the claimed
    /// key would let a stale-keyed entry resurrect the notification at drain.
    nonisolated func discardPendingNotifications(forSurfaceId surfaceId: UUID) {
        invalidateApprovalGenerations(global: false, workspaceID: nil, surfaceID: surfaceId)
        discardPendingNotifications { notification, _ in
            notification.key.surfaceId == surfaceId
        }
    }

    /// Clear-scoped discard: canonical surface identity when surface-scoped;
    /// live destination workspace when workspace-scoped.
    @MainActor
    func discardPendingNotificationsForClear(tabId: UUID, surfaceId: UUID?) {
        if let surfaceId {
            agentApprovalNotifications.cancel(surfaceID: surfaceId, clearDelivered: false)
            discardPendingNotifications(forSurfaceId: surfaceId)
            invalidateApprovalGenerations(global: false, workspaceID: nil, surfaceID: surfaceId)
        } else {
            cancelAgentApprovalNotifications(
                forLiveTabId: tabId,
                clearDelivered: false
            )
            discardPendingNotificationsResolvingLiveOwner(forTabId: tabId)
            invalidateApprovalGenerations(global: false, workspaceID: tabId, surfaceID: nil)
        }
    }

    @MainActor
    private func cancelAgentApprovalNotifications(
        forLiveTabId tabId: UUID,
        clearDelivered: Bool
    ) {
        agentApprovalNotifications.cancelPanes(clearDelivered: clearDelivered) {
            claimedTabId,
            surfaceId in
            guard let target = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: claimedTabId,
                surfaceId: surfaceId
            ) else {
                return claimedTabId == tabId
            }
            return target.tabId == tabId
        }
    }

    /// Phase 1 of the live-owner workspace clear (see
    /// `discardPendingNotificationsResolvingLiveOwner(forTabId:)`): the
    /// pending notification addresses, identified by their exact sequence.
    nonisolated func pendingNotificationAddressesSnapshot() -> [(sequence: UInt64, tabId: UUID, surfaceId: UUID?)] {
        lock.lock()
        defer { lock.unlock() }
        return pending.compactMap { entry in
            guard case .deliverNotification(let notification) = entry.mutation else { return nil }
            return (entry.sequence, notification.key.tabId, notification.key.surfaceId)
        }
    }

    /// Phase 2: discard exactly the snapshotted entries; anything enqueued
    /// after the snapshot keeps its place.
    nonisolated func discardPendingNotifications(sequences: Set<UInt64>) {
        guard !sequences.isEmpty else { return }
        lock.lock()
        pending.removeAll { entry in
            guard case .deliverNotification = entry.mutation else { return false }
            return sequences.contains(entry.sequence)
        }
        lock.unlock()
    }

    private func enqueueNotification(_ notification: QueuedTerminalNotification, coalesces: Bool) {
        let shouldScheduleDrain: Bool
        let removedCount: Int
        let pendingCount: Int
        let sequence: UInt64
        let generation: UInt64
        lock.lock()
        generation = currentNotificationGeneration
        let coalescingKey = coalesces
            ? TerminalNotificationCoalescingKey(
                generation: generation,
                notificationKey: notification.key
            )
            : nil
        let beforeCount = pending.count
        if let coalescingKey {
            pending.removeAll { entry in
                entry.notificationCoalescingKey == coalescingKey
            }
        }
        removedCount = beforeCount - pending.count
        nextSequence &+= 1
        sequence = nextSequence
        pending.append(TerminalSocketMutationEntry(
            sequence: sequence,
            mutation: .deliverNotification(notification),
            notificationGeneration: generation,
            notificationCoalescingKey: coalescingKey,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        pendingCount = pending.count
        lock.unlock()

#if DEBUG
        cmuxDebugLog(
            "notification.queue.enqueue seq=\(sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") coalesces=\(coalesces ? 1 : 0) removed=\(removedCount) pending=\(pendingCount) generation=\(generation) titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
        )
#endif

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueClear(
        _ mutation: (UInt64) -> TerminalSocketMutation,
        dropping shouldDrop: (QueuedTerminalNotification) -> Bool
    ) {
        let shouldScheduleDrain: Bool
        lock.lock()
        let boundary = currentNotificationGeneration
        currentNotificationGeneration &+= 1
        pending.removeAll { entry in
            if case .deliverNotification(let notification) = entry.mutation {
                return shouldDrop(notification)
            }
            return false
        }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation(boundary),
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private func enqueueBarrierMutation(_ mutation: TerminalSocketMutation) {
        let shouldScheduleDrain: Bool
        lock.lock()
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
            performReplaceKey: nil
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduleDrain()
    }

    private nonisolated func approvalMutationToken(
        workspaceID: UUID?,
        surfaceID: UUID?,
        capturesWorkspace: Bool = true
    ) -> AgentApprovalMutationToken {
        let resolvedWorkspaceID = capturesWorkspace
            ? (workspaceID ?? surfaceID.flatMap { approvalWorkspaceBySurface[$0] })
            : workspaceID
        return AgentApprovalMutationToken(
            global: approvalGlobalGeneration,
            workspace: resolvedWorkspaceID.map { approvalWorkspaceGenerations[$0] ?? 0 } ?? 0,
            surface: surfaceID.map { approvalSurfaceGenerations[$0] ?? 0 } ?? 0,
            workspaceID: resolvedWorkspaceID,
            surfaceID: surfaceID
        )
    }

    /// Must be called with `lock` held. A global reset is preferable to
    /// evicting individual UUID generations: evicting one key could make an
    /// old token look current again when its generation falls back to zero.
    private func ensureApprovalGenerationCapacityLocked(
        workspaceID: UUID?,
        surfaceID: UUID?
    ) {
        var projected = approvalWorkspaceGenerations.count
            + approvalSurfaceGenerations.count
            + approvalWorkspaceBySurface.count
        if let workspaceID, approvalWorkspaceGenerations[workspaceID] == nil {
            projected += 1
        }
        if let surfaceID {
            if approvalSurfaceGenerations[surfaceID] == nil { projected += 1 }
            if approvalWorkspaceBySurface[surfaceID] == nil { projected += 1 }
        }
        guard projected <= maxApprovalGenerationEntries else {
            approvalGlobalGeneration &+= 1
            approvalWorkspaceGenerations.removeAll(keepingCapacity: true)
            approvalSurfaceGenerations.removeAll(keepingCapacity: true)
            approvalWorkspaceBySurface.removeAll(keepingCapacity: true)
            return
        }
    }

    private nonisolated func invalidateApprovalGenerations(
        global: Bool,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) {
        lock.lock()
        ensureApprovalGenerationCapacityLocked(workspaceID: workspaceID, surfaceID: surfaceID)
        if global { approvalGlobalGeneration &+= 1 }
        if let workspaceID {
            approvalWorkspaceGenerations[workspaceID, default: 0] &+= 1
        }
        if let surfaceID {
            approvalSurfaceGenerations[surfaceID, default: 0] &+= 1
            approvalWorkspaceBySurface.removeValue(forKey: surfaceID)
        }
        lock.unlock()
    }

    /// Approval stages/resolutions are keyed mutations. Coalesce duplicate
    /// entries while the main actor is busy. A bounded admission rule then
    /// drops a new stage (or evicts the oldest stage for a resolution) once
    /// `maxPendingApprovalMutations` is reached, so a hook burst cannot turn
    /// the pending array into an unbounded backlog.
    private nonisolated func enqueueApprovalMutation(_ mutation: TerminalSocketMutation) {
        let shouldScheduleDrain: Bool
        lock.lock()
        switch mutation {
        case .stageAgentApproval(let stage, _):
            let beforeCount = pending.count
            pending.removeAll { entry in
                guard case .stageAgentApproval(let existing, _) = entry.mutation else { return false }
                return existing.surfaceID == stage.surfaceID
                    && existing.approvalID == stage.approvalID
            }
            pendingApprovalMutationCount -= beforeCount - pending.count
        case .resolveAgentApproval(let surfaceID, let approvalID, _):
            let beforeCount = pending.count
            pending.removeAll { entry in
                guard case .resolveAgentApproval(let existingSurfaceID, let existingID, _) = entry.mutation else { return false }
                return existingSurfaceID == surfaceID && existingID == approvalID
            }
            pendingApprovalMutationCount -= beforeCount - pending.count
        case .resolveAgentApprovalScope(let surfaceID, let scope, _):
            let beforeCount = pending.count
            pending.removeAll { entry in
                guard case .resolveAgentApprovalScope(let existingSurfaceID, let existingScope, _) = entry.mutation else { return false }
                return existingSurfaceID == surfaceID && existingScope == scope
            }
            pendingApprovalMutationCount -= beforeCount - pending.count
        default:
            break
        }
        if pendingApprovalMutationCount >= maxPendingApprovalMutations {
            if Self.isApprovalResolution(mutation),
               let evictionIndex = pending.firstIndex(where: { entry in
                   if case .stageAgentApproval = entry.mutation { return true }
                   return false
               }) ?? pending.firstIndex(where: { Self.isApprovalMutation($0.mutation) }) {
                pending.remove(at: evictionIndex)
                pendingApprovalMutationCount -= 1
            } else {
                // Stage admission is explicitly lossy under pressure. The
                // coordinator's settle window and later authoritative hook
                // events still provide the next opportunity to surface it.
                lock.unlock()
                return
            }
        }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: mutation,
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
            performReplaceKey: nil
        ))
        pendingApprovalMutationCount += 1
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain { drainScheduled = true }
        lock.unlock()
        if shouldScheduleDrain { scheduleDrain() }
    }

    private static func isApprovalMutation(_ mutation: TerminalSocketMutation) -> Bool {
        switch mutation {
        case .stageAgentApproval, .resolveAgentApproval, .resolveAgentApprovalScope:
            return true
        default:
            return false
        }
    }

    private static func isApprovalResolution(_ mutation: TerminalSocketMutation) -> Bool {
        switch mutation {
        case .resolveAgentApproval, .resolveAgentApprovalScope:
            return true
        default:
            return false
        }
    }

    private nonisolated func approvalTokenIsCurrent(
        _ token: AgentApprovalMutationToken,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard token.global == approvalGlobalGeneration else { return false }
        guard token.workspaceID == workspaceID || workspaceID == nil else { return false }
        guard token.surfaceID == surfaceID || surfaceID == nil else { return false }
        if let tokenWorkspaceID = token.workspaceID,
           token.workspace != (approvalWorkspaceGenerations[tokenWorkspaceID] ?? 0) {
            return false
        }
        if let tokenSurfaceID = token.surfaceID,
           token.surface != (approvalSurfaceGenerations[tokenSurfaceID] ?? 0) {
            return false
        }
        // Resolution tokens may be workspace-agnostic after an owner mapping
        // is retired; the surface generation above remains the stale-event
        // fence. Only compare the live owner when the token captured one.
        if let tokenSurfaceID = token.surfaceID,
           let tokenWorkspaceID = token.workspaceID,
           approvalWorkspaceBySurface[tokenSurfaceID] != tokenWorkspaceID {
            return false
        }
        return true
    }

    /// Last-write-wins `enqueueMainActorMutation`: drops any still-pending
    /// mutation with the same `replaceKey` before appending, so the survivor
    /// applies at its new enqueue position (the notification coalescing
    /// semantics above, for `.perform` mutations).
    ///
    /// `shouldEnqueue` executes synchronously while the bus ordering lock is
    /// held. It must remain bounded and must not call back into this bus.
    @discardableResult
    nonisolated func enqueueReplacingMainActorMutation(
        replaceKey: TerminalMutationReplaceKey,
        admitting shouldEnqueue: () -> Bool = { true },
        _ mutation: @escaping @MainActor () -> Void
    ) -> Bool {
        let shouldScheduleDrain: Bool
        lock.lock()
        guard shouldEnqueue() else {
            lock.unlock()
            return false
        }
        pending.removeAll { $0.performReplaceKey == replaceKey }
        nextSequence &+= 1
        pending.append(TerminalSocketMutationEntry(
            sequence: nextSequence,
            mutation: .perform(mutation),
            notificationGeneration: nil,
            notificationCoalescingKey: nil,
            performReplaceKey: replaceKey
        ))
        shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        if shouldScheduleDrain {
            scheduleDrain()
        }
        return true
    }

    private func discardPendingNotifications(
        advanceGeneration: Bool = false,
        where shouldDiscard: (QueuedTerminalNotification, UInt64) -> Bool
    ) {
        lock.lock()
        pending.removeAll { entry in
            guard case .deliverNotification(let notification) = entry.mutation,
                  let generation = entry.notificationGeneration else {
                return false
            }
            return shouldDiscard(notification, generation)
        }
        if advanceGeneration {
            currentNotificationGeneration &+= 1
        }
        lock.unlock()
    }

    private func scheduleDrain() {
#if DEBUG
        lock.lock()
        let suspended = drainsSuspendedForTesting
        lock.unlock()
        if suspended { return }
#endif
        Task { @MainActor [weak self] in
            self?.drainOnMainActor()
        }
    }

#if DEBUG
    nonisolated func setDrainsSuspendedForTesting(_ suspended: Bool) {
        let shouldScheduleDrain: Bool
        lock.lock()
        drainsSuspendedForTesting = suspended
        shouldScheduleDrain = !suspended && drainScheduled && !pending.isEmpty
        lock.unlock()

        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    @MainActor
    func drainForTesting() {
        while true {
            let batch = takeNextBatch()
            guard !batch.isEmpty else {
                markDrainCompleteIfEmpty()
                return
            }
            perform(batch)
        }
    }
#endif

    @MainActor
    private func drainOnMainActor() {
        let batch = takeNextBatch()
        guard !batch.isEmpty else {
            markDrainCompleteIfEmpty()
            return
        }

        perform(batch)

        lock.lock()
        let hasMore = !pending.isEmpty
        if !hasMore {
            drainScheduled = false
        }
        lock.unlock()

        if hasMore {
            scheduleDrain()
        }
    }

    private func takeNextBatch() -> [TerminalSocketMutationEntry] {
        lock.lock()
        let count = min(maxMutationsPerDrain, pending.count)
        let batch = Array(pending.prefix(count))
        if !batch.isEmpty {
            pending.removeFirst(count)
            pendingApprovalMutationCount -= batch.reduce(into: 0) { count, entry in
                if Self.isApprovalMutation(entry.mutation) {
                    count += 1
                }
            }
        }
        let remaining = pending.count
        lock.unlock()
#if DEBUG
        if !batch.isEmpty {
            cmuxDebugLog(
                "notification.queue.drain batch=\(batch.count) remaining=\(remaining) firstSeq=\(batch.first?.sequence ?? 0) lastSeq=\(batch.last?.sequence ?? 0)"
            )
        }
#endif
        return batch
    }

    private func markDrainCompleteIfEmpty() {
        lock.lock()
        if pending.isEmpty {
            drainScheduled = false
            lock.unlock()
            return
        }
        lock.unlock()

        scheduleDrain()
    }

    @MainActor
    private func perform(_ batch: [TerminalSocketMutationEntry]) {
        for entry in batch {
            switch entry.mutation {
            case .deliverNotification(let notification):
#if DEBUG
                cmuxDebugLog(
                    "notification.queue.perform seq=\(entry.sequence) workspace=\(notification.key.tabId.uuidString.prefix(8)) surface=\(notification.key.surfaceId?.uuidString.prefix(8) ?? "nil") titleLen=\(notification.title.count) subtitleLen=\(notification.subtitle.count) bodyLen=\(notification.body.count)"
                )
#endif
                let delivered = TerminalNotificationStore.shared.deliverQueuedNotification(
                    claimedTabId: notification.key.tabId,
                    surfaceId: notification.key.surfaceId,
                    title: notification.title,
                    subtitle: notification.subtitle,
                    body: notification.body,
                    replyShape: notification.replyShape,
                    agent: notification.agent,
                    correlationKey: notification.correlationKey,
                    notificationGeneration: entry.notificationGeneration ?? 0,
                    soundContext: notification.soundContext
                )
                if AgentApprovalNotificationCoordinator.isApprovalCorrelationKey(notification.correlationKey) {
                    // A missing live target is terminal for this episode: keep
                    // neither its expiry task nor its candidate strings around
                    // waiting for a pane that cannot receive the banner.
                    if !delivered, let correlationKey = notification.correlationKey {
                        dismissAgentApproval(
                            correlationKey: correlationKey,
                            workspaceID: notification.key.tabId,
                            surfaceID: notification.key.surfaceId
                        )
                    }
                } else if delivered {
                    // Retire ordinary agent state only after the replacement
                    // was accepted by the live-owner resolver.
                    if let surfaceID = notification.key.surfaceId {
                        cancelAgentApproval(surfaceID: surfaceID)
                    } else {
                        cancelAgentApprovals(workspaceID: notification.key.tabId)
                    }
                }
            case .clearAllNotifications(let boundary):
                agentApprovalNotifications.cancelAll(clearDelivered: false)
                TerminalNotificationStore.shared.clearAll(discardQueuedNotifications: false, throughNotificationGeneration: boundary)
            case .clearNotificationsForTab(let tabId, let boundary):
                cancelAgentApprovalNotifications(
                    forLiveTabId: tabId,
                    clearDelivered: false
                )
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForSurface(let tabId, let surfaceId, let boundary):
                agentApprovalNotifications.cancel(surfaceID: surfaceId, clearDelivered: false)
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    discardQueuedNotifications: false,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationsForCorrelation(let tabId, let surfaceId, let correlationKey, let boundary):
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    surfaceId: surfaceId,
                    correlationKey: correlationKey,
                    throughNotificationGeneration: boundary
                )
            case .clearNotificationCorrelation(let key, let correlationKey):
                // A pane may disappear between delivery and resolution. Clear
                // the claimed workspace when no live owner can be retargeted.
                let tabId = AppDelegate.shared?.agentNotificationDeliveryTarget(
                    claimedTabId: key.tabId,
                    surfaceId: key.surfaceId
                )?.tabId ?? key.tabId
                // Correlation clears can originate outside the coordinator's
                // own resolve callback. Retire any matching episode before
                // removing the persisted row so a late stage cannot recreate
                // the banner.
                _ = agentApprovalNotifications.dismissDelivered(correlationKey: correlationKey)
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: tabId,
                    correlationKey: correlationKey
                )
            case .stageAgentApproval(let stage, let token):
                guard approvalTokenIsCurrent(token, workspaceID: stage.workspaceID, surfaceID: stage.surfaceID) else { continue }
                agentApprovalNotifications.stage(
                    workspaceID: stage.workspaceID,
                    surfaceID: stage.surfaceID,
                    title: stage.title,
                    subtitle: stage.subtitle,
                    body: stage.body,
                    approvalID: stage.approvalID,
                    isDerived: stage.approvalIDIsDerived,
                    agent: stage.agent
                )
            case .resolveAgentApproval(let surfaceID, let approvalID, let token):
                guard approvalTokenIsCurrent(token, workspaceID: nil, surfaceID: surfaceID) else { continue }
                agentApprovalNotifications.resolve(surfaceID: surfaceID, approvalID: approvalID)
            case .resolveAgentApprovalScope(let surfaceID, let approvalScope, let token):
                guard approvalTokenIsCurrent(token, workspaceID: nil, surfaceID: surfaceID) else { continue }
                agentApprovalNotifications.resolve(surfaceID: surfaceID, approvalScope: approvalScope)
            case .perform(let mutation):
                mutation()
            }
        }
    }
}

extension TerminalNotificationStore {
    static func cachedDeliveryAuthorizationDecision(
        for state: NotificationAuthorizationState,
        isAppActive: Bool
    ) -> Bool? {
        switch state {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .denied:
            return false
        case .notDetermined:
            return isAppActive ? nil : false
        case .unknown:
            return nil
        }
    }

    /// Effects for the out-of-band fallback path, where cmux plays feedback
    /// itself because the OS will not deliver the banner.
    ///
    /// A user who explicitly turned cmux notifications off (`.denied`) asked
    /// for silence, so the direct `NSSound` fallback must not punch through
    /// the denial (https://github.com/manaflow-ai/cmux/issues/5650). Every
    /// other state keeps the audible fallback: fresh installs
    /// (`.notDetermined`) have expressed no preference, and granted states
    /// only reach the fallback when delivery itself failed.
    nonisolated static func fallbackEffects(
        _ effects: TerminalNotificationPolicyEffects,
        authorizationState: NotificationAuthorizationState
    ) -> TerminalNotificationPolicyEffects {
        guard authorizationState == .denied else { return effects }
        var silenced = effects
        silenced.sound = false
        return silenced
    }
}

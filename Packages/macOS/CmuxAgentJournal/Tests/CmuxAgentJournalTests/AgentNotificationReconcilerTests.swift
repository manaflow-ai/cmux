import Foundation
import Testing
@testable import CmuxAgentJournal

struct AgentNotificationReconcilerTests {
    private let workspace = UUID().uuidString
    private let surface = UUID().uuidString

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind, source: String,
                       turn: String? = "turn-1", request: String? = nil, pending: Bool = false,
                       notify: Bool = true, occurredAt: Int64? = nil, nativeID: String? = nil,
                       surfaceID: String? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                occurredAtMs: occurredAt ?? sequence, source: source, agentKey: source,
                sessionId: "session", workspaceId: workspace, surfaceId: surfaceID ?? surface,
                pendingWork: pending, attention: AgentAttentionContext(eventIdentity: nativeID,
                    turnIdentity: turn, requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "",
                        body: "Ready", category: kind == .turnCompleted ? "turn-complete" : "needs-permission") : nil)))
    }

    @Test(arguments: ["claude", "codex"])
    func duplicateAndReadReplayReserveOneDelivery(source: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source))
        let duplicate = reconciler.apply(event(3, .turnCompleted, source: source))
        let identity = try #require(first.identity)
        #expect(first.disposition == .accepted)
        #expect(duplicate.identity == identity)
        #expect(try store.claimNotification(identity: identity))
        #expect(try !store.claimNotification(identity: identity))
        // Read/dismiss does not delete the receipt. Reopening represents an app restart.
        store.close()
        let reopened = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        defer { reopened.close() }
        #expect(try !reopened.claimNotification(identity: identity))
    }

    @Test(arguments: ["claude", "codex"])
    func pendingStopDoesNotConsumeSettledCompletionOrApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        #expect(reconciler.apply(event(2, .turnCompleted, source: source, pending: true)).disposition == .delayed)
        let wait = reconciler.apply(event(3, .approvalRequested, source: source, request: "approval", pending: true))
        #expect(wait.disposition == .accepted)
        let done = reconciler.apply(event(4, .turnCompleted, source: source))
        #expect(done.disposition == .accepted)
        #expect(wait.identity != done.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func lateStopCannotSettleContinuingTurn(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source))
        let continuing = reconciler.apply(event(3, .turnStarted, source: source, turn: "turn-2", notify: false))
        let firstIdentity = try #require(first.identity)
        #expect(continuing.invalidatedCorrelationKeys == [firstIdentity])
        #expect(reconciler.apply(event(4, .turnCompleted, source: source)).disposition == .stale)
        let next = reconciler.apply(event(5, .questionRequested, source: source, turn: "turn-2", request: "question"))
        #expect(next.disposition == .accepted)
        #expect(next.identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func outOfOrderStopPreservesRealLaterWait(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let wait = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1", occurredAt: 30))
        #expect(reconciler.apply(event(3, .turnCompleted, source: source, occurredAt: 20)).disposition == .stale)
        let next = reconciler.apply(event(4, .approvalRequested, source: source, request: "r2", occurredAt: 40))
        #expect(next.disposition == .accepted)
        #expect(next.identity != wait.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func movedAndResumedSessionKeepsSemanticIdentity(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1"))
        let moved = reconciler.apply(event(3, .approvalRequested, source: source, request: "r1", surfaceID: UUID().uuidString))
        #expect(first.identity == moved.identity)
        let later = reconciler.apply(event(4, .approvalRequested, source: source, request: "r2", surfaceID: UUID().uuidString))
        #expect(later.identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func duplicateStartCannotEraseApprovalOrRearmCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false, nativeID: "prompt-1"))
        let first = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1"))
        let duplicate = reconciler.apply(event(3, .turnStarted, source: source, notify: false, nativeID: "prompt-1"))
        #expect(duplicate.disposition == .stale)
        #expect(duplicate.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.apply(event(4, .approvalRequested, source: source, request: "r1")).identity == first.identity)
    }

    @Test func contextPersistsAndIdempotentAppendRejectsChangedEvidence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        let draft = event(1, .approvalRequested, source: "claude", request: "request").draft
        _ = try store.append(draft)
        #expect(try store.events(afterSequence: 0, limit: 10).first?.draft == draft)
        #expect(try store.append(draft).replayed)
        var conflict = draft
        conflict.attention?.requestIdentity = "different"
        #expect(throws: AgentJournalStoreError.self) { try store.append(conflict) }
    }
    @Test(arguments: ["claude", "codex"])
    func resolvedRequestCannotReplayWhileNewApprovalRemainsDeliverable(source: String) {
        var reconciler = AgentNotificationReconciler()
        var resolved = event(1, .attentionResolved, source: source, request: "resolved", notify: false).draft
        resolved.declaredPhase = .running
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: resolved))
        #expect(reconciler.apply(event(2, .approvalRequested, source: source, request: "resolved")).disposition == .stale)
        #expect(reconciler.apply(event(3, .approvalRequested, source: source, request: "new")).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func detachedTurnStartCannotClearItsAlreadyObservedApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        let approval = reconciler.apply(event(1, .approvalRequested, source: source, request: "r1"))
        let lateStart = reconciler.apply(event(2, .turnStarted, source: source, notify: false))
        #expect(lateStart.disposition == .stale)
        #expect(lateStart.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.apply(event(3, .approvalRequested, source: source, request: "r1")).identity == approval.identity)
    }
    @Test(arguments: ["claude", "codex"])
    func observationsDoNotInvalidateCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(3, .stateChanged, source: source, notify: false, occurredAt: 30))
        #expect(reconciler.apply(event(2, .turnCompleted, source: source, occurredAt: 20)).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func explicitMessageIsIdempotentAndDoesNotSettleTheTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        let start = event(1, .turnStarted, source: source, notify: false)
        _ = reconciler.apply(start)
        let message = reconciler.apply(event(2, .messagePublished, source: source, request: "push"))
        #expect(message.disposition == .accepted)
        #expect(reconciler.apply(event(3, .messagePublished, source: source, request: "push")).identity == message.identity)
        #expect(reconciler.apply(event(4, .turnCompleted, source: source)).identity != message.identity)
    }
    @Test(arguments: ["claude", "codex"])
    func workObservationDoesNotResolveARealApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        var work = event(1, .stateChanged, source: source, request: "tool", notify: false).draft
        work.declaredPhase = .running
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: work))
        let approval = reconciler.apply(event(2, .approvalRequested, source: source, request: "tool", occurredAt: 30))
        #expect(approval.disposition == .accepted)
        work.occurredAtMs = 20
        let stale = reconciler.apply(AgentJournalEvent(sequence: 3, committedAtMs: 3, draft: work))
        #expect(stale.disposition == .stale)
        #expect(stale.invalidatedCorrelationKeys.isEmpty)
    }

    @Test(arguments: ["claude", "codex"])
    func lateResolutionRetiresOnlyItsOwnImmutableRequest(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        let old = reconciler.apply(event(1, .approvalRequested, source: source, request: "old", occurredAt: 10))
        let newer = reconciler.apply(event(2, .approvalRequested, source: source, request: "new", occurredAt: 30))
        let resolved = reconciler.apply(event(3, .attentionResolved, source: source, request: "old", notify: false, occurredAt: 20))
        let oldIdentity = try #require(old.identity)
        let newerIdentity = try #require(newer.identity)
        #expect(resolved.invalidatedCorrelationKeys == [oldIdentity])
        #expect(!resolved.invalidatedCorrelationKeys.contains(newerIdentity))
        #expect(reconciler.apply(event(4, .approvalRequested, source: source, request: "old")).disposition == .stale)
    }

    @Test(arguments: ["claude", "codex"])
    func delayedParentCompletionIsReleasedByLastChildWithoutTimer(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .childSpawned, source: source, request: "child", notify: false))
        #expect(reconciler.apply(event(3, .turnCompleted, source: source)).disposition == .delayed)
        let end = event(4, .childCompleted, source: source, request: "child", notify: false, occurredAt: 2)
        let released = reconciler.apply(end)
        #expect(released.disposition == .accepted)
        #expect(released.notificationEvent?.kind == .turnCompleted)
        #expect(released.notificationEvent?.draft.attention?.notification?.body == "Ready")
        #expect(reconciler.lifecycleEvent(end).draft.declaredPhase == .idle)
        #expect(reconciler.apply(event(5, .childCompleted, source: source, request: "child", notify: false)).identity == nil)
        #expect(reconciler.apply(event(6, .turnCompleted, source: source)).identity == released.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func continueCancelsACompletionWaitingForChildren(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .childSpawned, source: source, request: "child", notify: false))
        _ = reconciler.apply(event(3, .turnCompleted, source: source))
        _ = reconciler.apply(event(4, .turnStarted, source: source, turn: "turn-2", notify: false))
        #expect(reconciler.apply(event(5, .childCompleted, source: source, request: "child", notify: false)).identity == nil)
    }

    @Test(arguments: ["claude", "codex"])
    func identityLessTurnsDoNotCollapseRealIdenticalSubmissions(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: nil, notify: false))
        _ = reconciler.apply(event(2, .turnStarted, source: source, turn: nil, notify: false))
        let first = reconciler.apply(event(3, .turnCompleted, source: source, turn: nil))
        #expect(reconciler.apply(event(4, .turnCompleted, source: source, turn: nil)).identity == first.identity)
        _ = reconciler.apply(event(5, .turnStarted, source: source, turn: nil, notify: false))
        #expect(reconciler.apply(event(6, .turnCompleted, source: source, turn: nil)).identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func resumedCompletionWithAnUnseenTurnCanRecoverAMissedStart(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let old = reconciler.apply(event(2, .turnCompleted, source: source))
        _ = reconciler.apply(event(3, .sessionStarted, source: source, turn: nil, notify: false))
        let resumed = reconciler.apply(event(4, .turnCompleted, source: source, turn: "resumed-turn"))
        #expect(resumed.disposition == .accepted)
        #expect(resumed.identity != old.identity)
        #expect(reconciler.apply(event(5, .turnCompleted, source: source)).disposition == .stale)
    }

    @Test(arguments: ["claude", "codex"])
    func explicitMessagesRespectFreshnessAndSessionEnd(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(2, .turnStarted, source: source, notify: false))
        #expect(reconciler.apply(event(3, .messagePublished, source: source, request: "push", occurredAt: 1)).disposition == .stale)
        _ = reconciler.apply(event(4, .sessionEnded, source: source, notify: false))
        #expect(reconciler.apply(event(5, .messagePublished, source: source, request: "push")).disposition == .stale)
    }
    @Test(arguments: ["claude", "codex"])
    func idleReminderCannotReplayAReadCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let done = reconciler.apply(event(2, .turnCompleted, source: source))
        let idle = event(3, .idleObserved, source: source, turn: nil)
        #expect(reconciler.apply(idle).identity == done.identity)
        #expect(reconciler.lifecycleEvent(idle).draft.declaredPhase == .idle)
        _ = reconciler.apply(event(4, .turnStarted, source: source, turn: "next", notify: false))
        let delayed = reconciler.apply(event(5, .idleObserved, source: source, turn: nil, occurredAt: 20))
        #expect(delayed.disposition == .delayed)
        #expect(!delayed.projectsLifecycle)
        #expect(reconciler.apply(event(6, .approvalRequested, source: source, turn: "next", request: "real", occurredAt: 10)).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func anonymousReminderReusesPendingAttentionWithoutMaskingAnotherRequest(source: String) {
        var reconciler = AgentNotificationReconciler()
        let known = reconciler.apply(event(1, .approvalRequested, source: source, request: "known", occurredAt: 10))
        let reminder = reconciler.apply(event(2, .approvalRequested, source: source, request: nil, occurredAt: 30))
        #expect(reminder.identity == known.identity)
        #expect(!reminder.projectsLifecycle)
        #expect(reminder.notificationEvent?.draft.attention?.notification?.correlationKey == known.identity)
        let newer = reconciler.apply(event(3, .approvalRequested, source: source, request: "another", occurredAt: 20))
        #expect(newer.disposition == .accepted)
        #expect(newer.identity != known.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func independentParallelApprovalsCanArriveOutOfOrder(source: String) {
        var reconciler = AgentNotificationReconciler()
        let newer = reconciler.apply(event(1, .approvalRequested, source: source, request: "newer", occurredAt: 30))
        let earlier = reconciler.apply(event(2, .approvalRequested, source: source, request: "earlier", occurredAt: 20))
        #expect(earlier.disposition == .accepted)
        #expect(earlier.identity != newer.identity)
    }

    @Test func pruningRemovesPresentationContextButKeepsDeliveryReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        for sequence in 1...5 {
            _ = try store.append(event(Int64(sequence), .turnCompleted, source: "claude").draft)
        }
        #expect(try store.claimNotification(identity: "already-read"))
        try store.withDatabase { database in
            try AgentJournalStore.pruneIfNeeded(database, maximumCount: 3, retainedCount: 2)
            #expect(try AgentJournalStore.readAttention(database, eventId: "event-1") == nil)
            #expect(try AgentJournalStore.readAttention(database, eventId: "event-5") != nil)
        }
        #expect(try store.events(afterSequence: 0, limit: 10).map(\.draft.eventId) == ["event-4", "event-5"])
        #expect(try !store.claimNotification(identity: "already-read"))
    }
    @Test(arguments: ["claude", "codex"])
    func identitylessResponseClearsOnlyMatchingCurrentTurn(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let wait = reconciler.apply(event(2, .approvalRequested, source: source))
        let response = event(3, .attentionResolved, source: source, pending: true, notify: false)
        let resolved = reconciler.apply(response)
        #expect(resolved.invalidatedCorrelationKeys == [try #require(wait.identity)])
        #expect(reconciler.lifecycleEvent(response).draft.declaredPhase == .running)
        let later = reconciler.apply(event(4, .approvalRequested, source: source, turn: "turn-2"))
        let replay = event(5, .attentionResolved, source: source, pending: true, notify: false)
        #expect(reconciler.apply(replay).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(replay).draft.declaredPhase == .needsInput)
        #expect(later.identity != wait.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func ambiguousOrOlderIdentitylessResponsePreservesAttention(source: String) {
        for responseTurn in [nil, "previous", "turn-1"] as [String?] {
            var reconciler = AgentNotificationReconciler()
            _ = reconciler.apply(event(1, .approvalRequested, source: source, request: "first", occurredAt: 10))
            _ = reconciler.apply(event(2, .approvalRequested, source: source, request: "second", occurredAt: 20))
            let response = event(3, .attentionResolved, source: source, turn: responseTurn,
                                 pending: true, notify: false, occurredAt: 15)
            #expect(reconciler.apply(response).invalidatedCorrelationKeys.isEmpty)
            #expect(reconciler.lifecycleEvent(response).draft.declaredPhase == .needsInput)
        }
    }

    @Test(arguments: ["claude", "codex"])
    func lateResolutionCannotReopenCompletedTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .turnCompleted, source: source))
        let late = event(3, .attentionResolved, source: source, request: "ordinary-tool",
                         pending: true, notify: false, occurredAt: 1)
        #expect(reconciler.apply(late).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(late).draft.declaredPhase == .idle)
    }

}

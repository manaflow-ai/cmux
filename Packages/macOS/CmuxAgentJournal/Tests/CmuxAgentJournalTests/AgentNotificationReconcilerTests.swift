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
    func lateStopCannotSettleContinuingTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source))
        let continuing = reconciler.apply(event(3, .turnStarted, source: source, turn: "turn-2", notify: false))
        #expect(continuing.invalidatedCorrelationKeys == [first.identity!])
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
        var resolved = event(1, .stateChanged, source: source, request: "resolved", notify: false).draft
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
}

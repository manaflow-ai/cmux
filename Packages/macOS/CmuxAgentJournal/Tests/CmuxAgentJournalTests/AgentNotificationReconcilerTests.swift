import Foundation
import Testing
@testable import CmuxAgentJournal

struct AgentNotificationReconcilerTests {
    private let workspace = UUID().uuidString
    private let surface = UUID().uuidString

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind, source: String,
                       session: String = "session",
                       turn: String? = "turn-1", request: String? = nil, pending: Bool = false,
                       notify: Bool = true, occurredAt: Int64? = nil, nativeID: String? = nil,
                       surfaceID: String? = nil, declaredPhase: AgentLifecyclePhase? = nil,
                       nativeEvent: String? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                occurredAtMs: occurredAt ?? sequence, source: source, agentKey: source,
                sessionId: session, workspaceId: workspace, surfaceId: surfaceID ?? surface,
                pendingWork: pending, nativeEvent: nativeEvent, declaredPhase: declaredPhase, attention: AgentAttentionContext(eventIdentity: nativeID,
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

    @Test func recoveredReplacementInvalidatesTheOldErrorNotification() throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .errorReported, source: "claude", session: "old"))
        let replacement = reconciler.apply(event(2, .sessionStarted, source: "claude", session: "new"))
        #expect(replacement.invalidatedCorrelationKeys.count == 1)
        #expect(reconciler.apply(event(3, .errorReported, source: "claude", session: "old")).disposition == .stale)
        let recovered = reconciler.apply(event(4, .turnCompleted, source: "claude", session: "new"))
        #expect(recovered.disposition != .accepted || recovered.identity != replacement.identity)
    }

    @Test(arguments: ["antigravity", "grok"])
    func multiSessionAdapterStartKeepsSiblingSessionsLive(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .sessionStarted, source: source, session: "first", notify: false))
        let sibling = reconciler.apply(event(2, .sessionStarted, source: source, session: "second", notify: false))
        #expect(sibling.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.apply(event(3, .errorReported, source: source, session: "first")).disposition == .accepted)
        #expect(reconciler.apply(event(4, .errorReported, source: source, session: "second")).disposition == .accepted)
    }

    @Test func lateOlderSessionStartCannotSupersedeTheNewerOwner() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .errorReported, source: "claude", session: "old"))
        _ = reconciler.apply(event(2, .sessionStarted, source: "claude", session: "new", notify: false))

        let lateStart = reconciler.apply(
            event(1, .sessionStarted, source: "claude", session: "old", notify: false)
        )
        #expect(lateStart.disposition == .stale)
        #expect(lateStart.invalidatedCorrelationKeys.isEmpty)

        #expect(
            reconciler.apply(event(3, .errorReported, source: "claude", session: "new")).disposition
                == .accepted
        )
    }

    @Test func sessionStartOnSiblingSurfacePreservesTheOtherSurfaceSession() throws {
        var reconciler = AgentNotificationReconciler()
        let sibling = UUID().uuidString
        _ = reconciler.apply(event(1, .errorReported, source: "claude", session: "old"))
        let replacement = reconciler.apply(
            event(2, .sessionStarted, source: "claude", session: "new", notify: false, surfaceID: sibling)
        )
        #expect(replacement.invalidatedCorrelationKeys.isEmpty)
        #expect(
            reconciler.apply(event(3, .errorReported, source: "claude", session: "old")).disposition
                == .accepted
        )
    }

    @Test func movingASessionInvalidatesReceiptsFromItsOriginalSurface() throws {
        var reconciler = AgentNotificationReconciler()
        let newSurface = UUID().uuidString
        let error = reconciler.apply(event(1, .errorReported, source: "claude", session: "old"))
        let errorIdentity = try #require(error.identity)
        let moved = reconciler.apply(
            event(2, .turnStarted, source: "claude", session: "old", notify: false, surfaceID: newSurface)
        )
        #expect(moved.invalidatedCorrelationKeys == [errorIdentity])

        let replacement = reconciler.apply(
            event(3, .sessionStarted, source: "claude", session: "new", notify: false)
        )
        #expect(replacement.invalidatedCorrelationKeys.isEmpty)
    }

    @Test func messagePublishedMoveReturnsOriginInvalidationAndCommitsDestination() throws {
        var reconciler = AgentNotificationReconciler()
        let origin = UUID().uuidString
        let destination = UUID().uuidString
        let error = reconciler.apply(
            event(1, .errorReported, source: "claude", session: "old", surfaceID: origin)
        )
        let errorIdentity = try #require(error.identity)

        let moved = reconciler.apply(
            event(2, .messagePublished, source: "claude", session: "old", request: "push",
                  surfaceID: destination)
        )
        #expect(moved.disposition == .accepted)
        #expect(moved.invalidatedCorrelationKeys == [errorIdentity])
        let destinationError = reconciler.apply(
            event(3, .errorReported, source: "claude", session: "old", surfaceID: destination)
        )
        let destinationErrorIdentity = try #require(destinationError.identity)
        #expect(destinationError.disposition == .accepted)
        let late = reconciler.apply(
            event(4, .errorReported, source: "claude", session: "old", occurredAt: 1, surfaceID: origin)
        )
        #expect(late.disposition == .stale)
        #expect(late.invalidatedCorrelationKeys.isEmpty)
        let later = reconciler.apply(
            event(5, .messagePublished, source: "claude", session: "old", request: "later",
                  surfaceID: destination)
        )
        #expect(later.disposition == .accepted)
        #expect(later.invalidatedCorrelationKeys.isEmpty)

        let replacement = reconciler.apply(
            event(6, .sessionStarted, source: "claude", session: "new", notify: false,
                  surfaceID: destination)
        )
        #expect(replacement.disposition == .observation)
        #expect(replacement.invalidatedCorrelationKeys == [destinationErrorIdentity])
        #expect(
            reconciler.apply(
                event(7, .errorReported, source: "claude", session: "old", surfaceID: destination)
            ).disposition == .stale
        )
    }

    @Test func freshEventsFromRetiredSurfaceCannotMoveSessionBack() throws {
        var reconciler = AgentNotificationReconciler()
        let origin = UUID().uuidString
        let destination = UUID().uuidString
        _ = reconciler.apply(
            event(1, .errorReported, source: "claude", session: "moved", surfaceID: origin)
        )
        let moved = reconciler.apply(
            event(2, .messagePublished, source: "claude", session: "moved", request: "move",
                  surfaceID: destination)
        )
        #expect(moved.disposition == .accepted)

        let late = reconciler.apply(
            event(3, .errorReported, source: "claude", session: "moved", occurredAt: 3,
                  surfaceID: origin)
        )
        #expect(late.disposition == .stale)
        #expect(late.invalidatedCorrelationKeys.isEmpty)

        let moveBack = reconciler.apply(
            event(4, .sessionStarted, source: "claude", session: "moved", notify: false,
                  surfaceID: origin)
        )
        #expect(moveBack.disposition == .observation)
        #expect(
            reconciler.apply(
                event(5, .errorReported, source: "claude", session: "moved", surfaceID: origin)
            ).disposition == .accepted
        )
    }

    @Test func olderSessionStartCannotRetireNewerOriginProjection() {
        var reconciler = AgentNotificationReconciler()
        let origin = UUID().uuidString
        let destination = UUID().uuidString
        _ = reconciler.apply(
            event(1, .errorReported, source: "claude", session: "timestamped", occurredAt: 100,
                  surfaceID: origin)
        )

        let staleMove = reconciler.apply(
            event(2, .sessionStarted, source: "claude", session: "timestamped", notify: false,
                  occurredAt: 50, surfaceID: destination)
        )
        #expect(staleMove.disposition == .stale)
        #expect(
            reconciler.apply(
                event(3, .errorReported, source: "claude", session: "timestamped", occurredAt: 101,
                      surfaceID: origin)
            ).disposition == .accepted
        )
    }

    @Test func idleObservedMoveReturnsOriginInvalidation() throws {
        var reconciler = AgentNotificationReconciler()
        let origin = UUID().uuidString
        let destination = UUID().uuidString
        let error = reconciler.apply(
            event(1, .errorReported, source: "claude", session: "old", surfaceID: origin)
        )
        let errorIdentity = try #require(error.identity)

        let moved = reconciler.apply(
            event(2, .idleObserved, source: "claude", session: "old", notify: false,
                  surfaceID: destination)
        )
        #expect(moved.disposition == .delayed)
        #expect(moved.invalidatedCorrelationKeys == [errorIdentity])
        #expect(
            reconciler.apply(
                event(1, .errorReported, source: "claude", session: "old", surfaceID: origin)
            ).disposition == .stale
        )
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
    func sameSessionStartRetiresPriorNotification(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        let failure = reconciler.apply(event(1, .errorReported, source: source))
        let failureIdentity = try #require(failure.identity)
        let recovery = event(2, .sessionStarted, source: source, turn: nil, notify: false)

        let recovered = reconciler.apply(recovery)
        #expect(recovered.disposition == .observation)
        #expect(recovered.invalidatedCorrelationKeys == [failureIdentity])
        #expect(reconciler.lifecycleEvent(recovery).draft.kind == .sessionStarted)
        #expect(
            reconciler.apply(event(3, .errorReported, source: source)).disposition == .accepted
        )
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

    @Test(arguments: ["grok", "claude"])
    func structuredIdleReminderAfterCompletionDeliversWithoutReopeningAttention(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let done = reconciler.apply(event(2, .turnCompleted, source: source))
        var reminder = event(3, .idleObserved, source: source).draft
        reminder.attention?.notification?.category = "idle-reminder"

        let delivered = reconciler.apply(AgentJournalEvent(sequence: 3, committedAtMs: 1003, draft: reminder))
        #expect(delivered.disposition == .accepted)
        #expect(delivered.identity != done.identity)
        #expect(!delivered.projectsLifecycle)
        let doneIdentity = try #require(done.identity)
        #expect(delivered.remindedCompletion == .init(identity: doneIdentity, correlationKey: doneIdentity))
        #expect(reconciler.lifecycleEvent(AgentJournalEvent(sequence: 3, committedAtMs: 1003, draft: reminder)).draft.declaredPhase == .idle)

        _ = reconciler.apply(event(4, .sessionEnded, source: source, notify: false))
        var lateReminder = event(5, .idleObserved, source: source).draft
        lateReminder.attention?.notification?.category = "idle-reminder"
        #expect(reconciler.apply(AgentJournalEvent(sequence: 5, committedAtMs: 1005, draft: lateReminder)).disposition == .delayed)
    }

    private func idleReminder(_ sequence: Int64, source: String, turn: String? = "turn-1",
                              occurredAt: Int64? = nil) -> AgentJournalEvent {
        var reminder = event(sequence, .idleObserved, source: source, turn: turn, occurredAt: occurredAt).draft
        reminder.attention?.notification?.category = "idle-reminder"
        return AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence, draft: reminder)
    }

    @Test(arguments: ["grok", "claude"])
    func idleReminderLinksOnlyItsOwnTurnsDeliveredCompletion(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: nil, notify: false))
        // A settled turn whose Stop carried no notification has nothing to repeat.
        _ = reconciler.apply(event(2, .turnCompleted, source: source, turn: nil, notify: false))
        #expect(reconciler.apply(idleReminder(3, source: source, turn: nil)).remindedCompletion == nil)

        // The next identity-less turn links its own completion, with its key.
        _ = reconciler.apply(event(4, .turnStarted, source: source, turn: nil, notify: false))
        var stop = event(5, .turnCompleted, source: source, turn: nil).draft
        stop.attention?.notification?.correlationKey = "stop-key"
        let done = reconciler.apply(AgentJournalEvent(sequence: 5, committedAtMs: 1005, draft: stop))
        let reminder = reconciler.apply(idleReminder(6, source: source, turn: nil))
        #expect(reminder.disposition == .accepted)
        let doneIdentity = try #require(done.identity)
        #expect(reminder.remindedCompletion == .init(identity: doneIdentity, correlationKey: "stop-key"))
    }

    /// A continuation without UserPromptSubmit reopens the settled turn. Its
    /// Stop is deduplicated against the first completion, so the reminder must
    /// not be linked to (and suppressed by) that already-read completion.
    @Test(arguments: ["claude"])
    func reminderAfterPromptlessContinuationIsNotLinkedToTheReadCompletion(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: nil, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source, turn: nil))
        #expect(first.disposition == .accepted)
        _ = reconciler.apply(event(3, .stateChanged, source: source, turn: nil, notify: false,
                                   occurredAt: 20, declaredPhase: .running, nativeEvent: "PreToolUse"))
        let second = reconciler.apply(event(4, .turnCompleted, source: source, turn: nil, occurredAt: 30))
        #expect(second.identity == first.identity)
        let reminder = reconciler.apply(idleReminder(5, source: source, turn: nil, occurredAt: 31))
        #expect(reminder.disposition == .accepted)
        #expect(reminder.remindedCompletion == nil)

        // A real next turn links its own completion again.
        _ = reconciler.apply(event(6, .turnStarted, source: source, turn: nil, notify: false, occurredAt: 40))
        let third = reconciler.apply(event(7, .turnCompleted, source: source, turn: nil, occurredAt: 41))
        let thirdIdentity = try #require(third.identity)
        let nextReminder = reconciler.apply(idleReminder(8, source: source, turn: nil, occurredAt: 42))
        #expect(nextReminder.remindedCompletion?.identity == thirdIdentity)
    }

    @Test func remindedCompletionIsAcknowledgedOnlyAfterRecordingAndRead() {
        let completion = AgentNotificationDecision.RemindedCompletion(identity: "done", correlationKey: "done")
        #expect(completion.isAcknowledged(completionWasRecorded: true, completionIsUnread: false))
        #expect(!completion.isAcknowledged(completionWasRecorded: true, completionIsUnread: true))
        #expect(!completion.isAcknowledged(completionWasRecorded: false, completionIsUnread: false))
    }

    @Test(arguments: ["claude", "codex"])
    func toolActivityReopensAContinuationWithoutPromptSubmit(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: "first", notify: false))
        let activity = event(2, .stateChanged, source: source, turn: "continuation", notify: false,
                             occurredAt: 20, declaredPhase: .running)
        _ = reconciler.apply(activity)
        #expect(reconciler.lifecycleEvent(activity).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func identitylessToolActivityReopensAContinuationWithoutPromptSubmit(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: nil, notify: false, occurredAt: 10))
        let activity = event(2, .stateChanged, source: source, turn: nil, notify: false,
                             occurredAt: 20, declaredPhase: .running, nativeEvent: "PreToolUse")
        _ = reconciler.apply(activity)
        #expect(reconciler.lifecycleEvent(activity).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func identitylessToolResolutionReopensAContinuationWithoutPromptSubmit(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: nil, notify: false, occurredAt: 10))
        let result = event(2, .attentionResolved, source: source, turn: nil, request: "tool",
                           pending: false, notify: false, occurredAt: 20, declaredPhase: .running,
                           nativeEvent: "PreToolUse")
        _ = reconciler.apply(result)
        #expect(reconciler.lifecycleEvent(result).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func identitylessLateStopCannotSettleAContinuation(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: nil, notify: false, occurredAt: 10))
        let activity = event(2, .stateChanged, source: source, turn: nil, notify: false,
                             occurredAt: 20, declaredPhase: .running, nativeEvent: "PreToolUse")
        _ = reconciler.apply(activity)
        let lateStop = event(3, .turnCompleted, source: source, turn: nil, notify: false, occurredAt: 10)
        #expect(reconciler.apply(lateStop).disposition == .stale)
        #expect(reconciler.lifecycleEvent(activity).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func identitylessPostToolResultKeepsSettledCompletionIdle(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: nil, notify: false, occurredAt: 10))
        let result = event(2, .stateChanged, source: source, turn: nil, notify: false,
                           occurredAt: 20, declaredPhase: .running, nativeEvent: "PostToolUse")
        _ = reconciler.apply(result)
        #expect(reconciler.lifecycleEvent(result).draft.declaredPhase == .idle)
    }

    @Test(arguments: ["claude", "codex"])
    func backgroundWorkResolutionKeepsThePaneRunning(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: "turn-1", notify: false))
        _ = reconciler.apply(event(2, .turnCompleted, source: source, turn: "turn-1",
                                   pending: true, notify: false))
        let resumed = event(3, .attentionResolved, source: source, turn: "turn-1",
                             pending: true, notify: false, declaredPhase: .running)
        _ = reconciler.apply(resumed)
        #expect(reconciler.lifecycleEvent(resumed).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func idlePromptDoesNotSettleAnActiveTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: "turn-1", notify: false))
        let idlePrompt = event(2, .idleObserved, source: source, turn: "turn-1", notify: false, occurredAt: 20)
        _ = reconciler.apply(idlePrompt)
        #expect(reconciler.lifecycleEvent(idlePrompt).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func lateStopCannotSettleAContinuationReopenedByActivity(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source, turn: "first", notify: false, occurredAt: 10))
        let activity = event(2, .stateChanged, source: source, turn: "continuation", notify: false,
                             occurredAt: 20, declaredPhase: .running)
        _ = reconciler.apply(activity)
        let lateStop = event(3, .turnCompleted, source: source, turn: "first", notify: false, occurredAt: 10)
        #expect(reconciler.apply(lateStop).disposition == .stale)
        #expect(reconciler.lifecycleEvent(activity).draft.declaredPhase == .running)
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
    func idleAttentionResolutionProjectsIdle(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .questionRequested, source: source, request: "idle-dialog"))
        let response = event(3, .attentionResolved, source: source, request: "idle-dialog",
                             notify: false, declaredPhase: .idle)
        _ = reconciler.apply(response)
        #expect(reconciler.lifecycleEvent(response).draft.declaredPhase == .idle)
    }

    @Test(arguments: ["claude", "codex"])
    func runningToolResultKeepsASettledTurnIdle(source: String) {
        // A same-turn result can be a late delivery from the completed turn.
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnCompleted, source: source))
        let result = event(2, .attentionResolved, source: source, request: "ordinary-tool",
                           notify: false, declaredPhase: .running)
        #expect(reconciler.apply(result).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(result).draft.declaredPhase == .idle)
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

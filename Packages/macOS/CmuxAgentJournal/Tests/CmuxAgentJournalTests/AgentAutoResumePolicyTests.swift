import Testing
@testable import CmuxAgentJournal

@Suite("Agent auto-resume policy")
struct AgentAutoResumePolicyTests {
    private let surface = "5B1E1B8E-0C0A-4C8C-9A55-2C5B1F0D1A01"

    @Test(arguments: [
        "overloaded: Overloaded",
        "rate_limit: Rate limit reached",
        "server_error: Internal server error",
        "rate_limit: Too many requests",
        "Selected model is at capacity. Please try a different model.",
        "stream disconnected before completion: error sending request",
        "Connection error: ECONNRESET",
        "API Error: 529 {\"type\":\"overloaded_error\"}",
        "Request timed out.",
        "connection_dropped: Connection reset by server",
        "api_error: API Error: 500 Internal Server Error",
    ])
    func retryableFailures(detail: String) {
        #expect(AgentRetryableFailureClassifier().isRetryable(detail: detail))
    }

    @Test(arguments: [
        nil,
        "",
        "unknown",
        "authentication_failed: invalid x-api-key",
        "billing_error: credit balance too low",
        "rate_limit: You've hit your usage limit. Resets at 5pm.",
        "usage_limit: You've hit your weekly limit · resets Oct 3 at 9am",
        "api_error: Something went wrong",
        "invalid_request: prompt is too long",
        "max_output_tokens",
        "The task wrote 15000 lines",
        "connection refused: invalid proxy configuration",
        "network access denied by sandbox",
        "timeout while waiting for local approval",
    ])
    func permanentOrUnknownFailures(detail: String?) {
        #expect(!AgentRetryableFailureClassifier().isRetryable(detail: detail))
    }

    @Test func retryableErrorSchedulesWithBackoffUntilTheStreakEnds() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1), .seconds(2)])
        guard case let .schedule(_, attempt, delay, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(attempt == 1)
        #expect(delay == .seconds(1))
        #expect(tracker.resumeSent(surfaceId: surface, token: token) == 1)

        guard case let .schedule(_, second, secondDelay, secondToken) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a second schedule")
            return
        }
        #expect(second == 2)
        #expect(secondDelay == .seconds(2))
        #expect(tracker.resumeSent(surfaceId: surface, token: secondToken) == 2)

        // The streak is spent: a third failure waits for a human.
        #expect(tracker.observe(kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded") == .none)
        #expect(tracker.totalResumes(surfaceId: surface) == 2)
    }

    @Test func aCompletedTurnEndsTheStreakAndClearsTheTotal() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        _ = tracker.resumeSent(surfaceId: surface, token: token)
        #expect(tracker.totalResumes(surfaceId: surface) == 1)
        #expect(tracker.observe(kind: .turnCompleted, surfaceId: surface, isSubagent: false, detail: nil) == .none)
        // The agent recovered, so the "Auto-resumed ×N" marker has nothing
        // left to say.
        #expect(tracker.totalResumes(surfaceId: surface) == 0)
        #expect(tracker.observe(kind: .turnStarted, surfaceId: surface, isSubagent: false, detail: nil) == .none)
        guard case .schedule(_, 1, _, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("a new streak should start at attempt 1")
            return
        }
    }

    /// Claude Code's StopFailure for a dropped connection, as journaled.
    private static let droppedConnectionDetail =
        "connection_dropped: API Error: Connection to the API was lost (StreamSuspended)"

    /// Feeds live events through the notification reconciler and the tracker
    /// the way the app's journal lifecycle center does: the reconciler's turn
    /// read before and after `apply` goes to the tracker.
    private struct LiveObservation {
        var reconciler = AgentNotificationReconciler()
        var tracker: AgentAutoResumeTracker
        var sequence: Int64 = 0
        /// Turn identity events carry unless they name one or have none.
        var currentTurn = "turn-1"
        let surface: String

        init(surface: String, delays: [Duration] = AgentAutoResumeTracker.defaultDelays) {
            self.surface = surface
            tracker = AgentAutoResumeTracker(delays: delays)
        }

        mutating func observe(
            _ kind: AgentJournalEventKind, child: String? = nil, detail: String? = nil, notify: Bool = false,
            turn: String? = nil, identityless: Bool = false, pendingWork: Bool = false, nativeEvent: String? = nil,
            declaredPhase: AgentLifecyclePhase? = nil, isSubagent: Bool = false
        ) -> AgentAutoResumeTracker.Action {
            sequence += 1
            if let turn { currentTurn = turn }
            let draft = AgentJournalEventDraft(
                eventId: "event-\(sequence)", kind: kind, occurredAtMs: sequence, source: "claude",
                agentKey: "claude", sessionId: "session", workspaceId: "workspace", surfaceId: surface,
                isSubagent: isSubagent, pendingWork: pendingWork, nativeEvent: nativeEvent,
                declaredPhase: declaredPhase, detail: detail,
                attention: AgentAttentionContext(
                    turnIdentity: identityless ? nil : currentTurn, requestIdentity: child,
                    notification: notify ? AgentJournalNotification(
                        title: "Agent", subtitle: "", body: "Ready", category: "turn-complete") : nil))
            let event = AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence, draft: draft)
            let turnOverBefore = reconciler.turnIsOver(for: event)
            // The app hands only non-stale events to auto-resume. These tests
            // never mean to send one, so a stale event is a broken scenario.
            guard reconciler.apply(event).disposition != .stale else {
                Issue.record("\(kind) was stale for the reconciler")
                return .none
            }
            return tracker.observe(
                kind: kind, surfaceId: surface, isSubagent: isSubagent, detail: detail, sessionId: "session",
                turnOverBefore: turnOverBefore, turnOverAfter: reconciler.turnIsOver(for: event)
            )
        }

        /// The pane's own idle settlement, journaled before the agent's Stop.
        mutating func paneSettles() -> AgentAutoResumeTracker.Action {
            observe(.turnCompleted, identityless: true, nativeEvent: AgentJournalEventDraft.paneIdleSettlementNativeEvent)
        }

        mutating func expectSchedule(
            attempt: Int, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
        ) -> UInt64? {
            guard case let .schedule(_, scheduled, _, token) = observe(.errorReported, detail: "overloaded"),
                  scheduled == attempt else {
                Issue.record(comment, sourceLocation: sourceLocation)
                return nil
            }
            return token
        }
    }

    @Test func aLateErrorAfterACompletedTurnDoesNotSchedule() {
        // The turn ended normally, then a dark wake reported a dropped
        // connection an hour later with no prompt in between.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.sessionStarted) == .none)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted, notify: true) == .none)
        #expect(live.observe(.idleObserved) == .none)
        #expect(live.observe(.errorReported, detail: Self.droppedConnectionDetail) == .none)

        // The next turn can be resumed again.
        #expect(live.observe(.turnStarted, turn: "turn-2") == .none)
        guard case .schedule(_, 1, _, _) = live.observe(.errorReported, detail: Self.droppedConnectionDetail) else {
            Issue.record("an error in a new turn should schedule")
            return
        }
    }

    @Test func aRepeatedLateErrorStillDoesNotSchedule() {
        // The first late report moves the session to its error phase. That
        // must not make the finished turn look live to the next report.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
        #expect(live.observe(.errorReported, detail: Self.droppedConnectionDetail) == .none)
    }

    @Test func aLateErrorAfterTheFirstCompletedTurnTheAppSeesDoesNotSchedule() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func aNewTurnAfterACompletedTurnLetsTheNextErrorSchedule() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.turnStarted, turn: "turn-2") == .none)
        _ = live.expectSchedule(attempt: 1, "an error in the next turn should schedule")
    }

    @Test func toolActivityWithoutAPromptReopensTheTurn() {
        // A continuation can start without a prompt hook (a background task
        // finishing, for one); its fresh tool activity shows it working.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.stateChanged, identityless: true, nativeEvent: "PreToolUse", declaredPhase: .running) == .none)
        _ = live.expectSchedule(attempt: 1, "tool activity after a completed turn should let an error schedule")
    }

    @Test func anAnswerThatContinuesWorkReopensTheTurn() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.questionRequested, child: "question", notify: true) == .none)
        #expect(live.observe(.attentionResolved, child: "question", pendingWork: true, declaredPhase: .running) == .none)
        _ = live.expectSchedule(attempt: 1, "work after an answered question should let an error schedule")
    }

    @Test(arguments: [
        AgentJournalEventKind.approvalRequested,
        .questionRequested,
        .planReviewRequested,
    ])
    func aWaitForAHumanAfterACompletedTurnKeepsTheTurnOver(kind: AgentJournalEventKind) {
        // Older Claude Code idle reminders read as a question. Waiting on a
        // human is not a running turn, so a late error still must not resume.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(kind, child: "request", notify: true) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func aCompletionWithBackgroundWorkLetsTheNextErrorSchedule() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted, pendingWork: true) == .none)
        _ = live.expectSchedule(attempt: 1, "the turn continues while background work runs")
    }

    @Test func thePanesSettlementLetsASlowStopFailureSchedule() {
        // The app settles a quiet pane after a 3 s grace; the agent's own
        // StopFailure for that turn can land after it.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.paneSettles() == .none)
        _ = live.expectSchedule(attempt: 1, "a failure after the pane's settlement should schedule")
    }

    @Test func aCompletionThatDoesNotEndTheTurnKeepsTheFailingStreak() {
        // A resumed turn that fails again, with the pane's idle settlement
        // landing before its StopFailure, must keep backing off and stop.
        var live = LiveObservation(surface: surface, delays: [.seconds(1), .seconds(2)])
        #expect(live.observe(.turnStarted) == .none)
        guard let token = live.expectSchedule(attempt: 1, "expected a schedule") else { return }
        #expect(live.tracker.resumeSent(surfaceId: surface, token: token) == 1)
        #expect(live.observe(.turnStarted, turn: "turn-2") == .none)
        #expect(live.paneSettles() == .none)
        #expect(live.tracker.totalResumes(surfaceId: surface) == 1)
        _ = live.expectSchedule(attempt: 2, "the streak should continue at attempt 2")
    }

    @Test func aCompletionThatDoesNotEndTheTurnCancelsAPendingResume() {
        var tracker = AgentAutoResumeTracker()
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(tracker.observe(
            kind: .turnCompleted, surfaceId: surface, isSubagent: false, detail: nil, turnOverAfter: false
        ) == .cancel(surfaceId: surface))
        #expect(!tracker.isPending(surfaceId: surface, token: token))
        #expect(tracker.resumeSent(surfaceId: surface, token: token) == nil)
    }

    @Test func thePanesSettlementAfterAFinalStopKeepsTheTurnOver() {
        // The Stop was still queued when the pane settled, so the synthetic
        // completion lands after it. It does not make the turn provisional.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.paneSettles() == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func theAgentsStopAfterThePanesSettlementEndsTheTurn() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.paneSettles() == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test(arguments: [
        AgentLifecyclePhase.idle,
        .needsInput,
        .backgroundWorkPending,
        .error,
        .unknown,
    ])
    func aStateChangeDeclaringANonRunningPhaseKeepsTheTurnOver(phase: AgentLifecyclePhase) {
        // Codex corrects a stale prompt-submit for a finished turn with a
        // state change that names the stored, non-running phase.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.stateChanged, declaredPhase: phase) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func aStaleTurnCorrectionClosesTheTurnASpuriousStartReopened() {
        // Codex can journal a turn-started for a prompt-submit that belongs to
        // a finished turn, then correct it with the store's idle phase. The
        // correction closes the turn again, so a late error is ignored.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.turnStarted, turn: "turn-2") == .none)
        #expect(live.observe(.stateChanged, detail: "stale-turn-corrected", declaredPhase: .idle) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func aChildThatFinishesAfterTheFinalStopKeepsTheTurnOver() {
        // The root stops while a child is still running. The child's later
        // completion leaves the session idle, so it is not work starting
        // again and a late error must not schedule a resume.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.childSpawned, child: "child") == .none)
        #expect(live.observe(.turnCompleted, notify: true) == .none)
        #expect(live.observe(.childCompleted, child: "child") == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
        #expect(live.tracker.totalResumes(surfaceId: surface) == 0)
    }

    @Test func aStopWithAChildStillRunningEndsTheTurn() {
        // A background subagent, or one whose SubagentStop never came, is
        // still listed at the root's Stop. The turn is over: a late error is
        // not resumed, and the "Auto-resumed ×N" marker has nothing left to say.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        guard let token = live.expectSchedule(attempt: 1, "expected a schedule") else { return }
        #expect(live.tracker.resumeSent(surfaceId: surface, token: token) == 1)
        #expect(live.observe(.turnStarted, turn: "turn-2") == .none)
        #expect(live.observe(.childSpawned, child: "child") == .none)
        #expect(live.observe(.turnCompleted, notify: true) == .none)
        #expect(live.tracker.totalResumes(surfaceId: surface) == 0)
        #expect(live.observe(.errorReported, detail: Self.droppedConnectionDetail) == .none)
    }

    @Test func aBlockedStopThatKeepsWorkingLetsItsFailureSchedule() {
        // A Stop hook that blocks continues the same turn, so its tool
        // activity carries the stopped turn's identity.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.stateChanged, nativeEvent: "PreToolUse", declaredPhase: .running) == .none)
        _ = live.expectSchedule(attempt: 1, "a failure in work after a blocked Stop should schedule")
    }

    @Test func aToolResultReceivedAfterTheStopKeepsTheTurnOver() {
        // The stopped turn's last PostToolUse can reach the app after its Stop.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted) == .none)
        #expect(live.observe(.stateChanged, nativeEvent: "PostToolUse", declaredPhase: .running) == .none)
        #expect(live.observe(.errorReported, detail: "overloaded") == .none)
    }

    @Test func aLateErrorAfterTheSessionEndedDoesNotSchedule() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.sessionStarted) == .none)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.sessionEnded) == .none)
        #expect(live.observe(.errorReported, detail: Self.droppedConnectionDetail) == .none)
    }

    @Test func aChildSpawnedAfterTheFinalStopReopensTheTurn() {
        // A new child after the Stop is the session running again, so a
        // failure in that work still gets its resume.
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted, notify: true) == .none)
        #expect(live.observe(.childSpawned, child: "late-child") == .none)
        _ = live.expectSchedule(attempt: 1, "an error after a child spawned past the Stop should schedule a resume")
    }

    @Test func aSubagentsCompletedTurnDoesNotHoldBackTheParentsError() {
        var live = LiveObservation(surface: surface)
        #expect(live.observe(.turnStarted) == .none)
        #expect(live.observe(.turnCompleted, isSubagent: true) == .none)
        _ = live.expectSchedule(attempt: 1, "a subagent's completion must not end the parent's turn")
    }

    /// Subrouter's 503 when every pooled account is exhausted, as Claude Code
    /// reports it, carrying the time the first account frees up.
    private static let exhaustedPoolDetail = "api_error: API Error: 503 no non-exhausted claude accounts available; "
        + "next account frees up in 47m (retry after 2820s). This is a server-side issue, usually temporary — "
        + "try again in a moment. If it persists, check your inference gateway (127.0.0.1:31415)."

    @Test func aRetryAfterHintIsParsedFromTheFailure() {
        let classifier = AgentRetryableFailureClassifier()
        #expect(classifier.isRetryable(detail: Self.exhaustedPoolDetail))
        #expect(classifier.retryAfter(detail: Self.exhaustedPoolDetail) == .seconds(2820))
        #expect(classifier.retryAfter(detail: "Retry After 90s") == .seconds(90))
        #expect(classifier.retryAfter(detail: "overloaded") == nil)
        #expect(classifier.retryAfter(detail: "retry after 0s") == nil)
        #expect(classifier.retryAfter(detail: "retry after 2820 lines") == nil)
        #expect(classifier.retryAfter(detail: "retry after 99999999999999999999999s") == nil)
        #expect(classifier.retryAfter(detail: nil) == nil)
    }

    @Test func aRetryAfterHintWaitsForCapacityInsteadOfTheBackoff() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(20)], retryHintJitterSeconds: 0...0)
        guard case let .schedule(_, attempt, delay, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: Self.exhaustedPoolDetail
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(attempt == 1)
        #expect(delay == .seconds(2820))
    }

    @Test func aRetryAfterHintIsSpreadByTheJitter() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(20)], retryHintJitterSeconds: 30...180)
        guard case let .schedule(_, _, delay, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: Self.exhaustedPoolDetail
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(delay >= .seconds(2850))
        #expect(delay <= .seconds(3000))
    }

    @Test func aShortRetryAfterHintNeverUndercutsTheBackoff() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(45)], retryHintJitterSeconds: 0...0)
        guard case let .schedule(_, _, delay, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "API Error: 503 busy (retry after 5s)"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(delay == .seconds(45))
    }

    @Test(arguments: [
        AgentJournalEventKind.turnStarted,
        .approvalRequested,
        .questionRequested,
        .planReviewRequested,
        .attentionResolved,
        .sessionEnded,
    ])
    func activityOrAHumanPromptCancelsAPendingResume(kind: AgentJournalEventKind) {
        var tracker = AgentAutoResumeTracker()
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(tracker.observe(kind: kind, surfaceId: surface, isSubagent: false, detail: nil) == .cancel(surfaceId: surface))
        #expect(!tracker.isPending(surfaceId: surface, token: token))
        #expect(tracker.resumeSent(surfaceId: surface, token: token) == nil)
    }

    @Test func idleAfterAnErrorKeepsThePendingResume() {
        var tracker = AgentAutoResumeTracker()
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(tracker.observe(kind: .idleObserved, surfaceId: surface, isSubagent: false, detail: nil) == .none)
        #expect(tracker.isPending(surfaceId: surface, token: token))
    }

    @Test func aDetailLessEchoOfTheErrorKeepsThePendingResume() {
        // A StopFailure also journals through the error notification, which
        // carries no failure detail. That echo must not cancel the resume.
        var tracker = AgentAutoResumeTracker()
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded: Overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(tracker.observe(kind: .errorReported, surfaceId: surface, isSubagent: false, detail: nil) == .none)
        #expect(tracker.isPending(surfaceId: surface, token: token))
        #expect(
            tracker.observe(kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "usage_limit: Weekly limit")
                == .cancel(surfaceId: surface)
        )
    }

    @Test func aNewSessionCancelsAResumeBelongingToThePreviousSession() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported,
            surfaceId: surface,
            isSubagent: false,
            detail: "overloaded",
            sessionId: "session-a"
        ) else {
            Issue.record("expected a schedule")
            return
        }

        #expect(
            tracker.observe(
                kind: .sessionStarted,
                surfaceId: surface,
                isSubagent: false,
                detail: nil,
                sessionId: "session-b"
            ) == .cancel(surfaceId: surface)
        )
        #expect(!tracker.isPending(surfaceId: surface, token: token))
        #expect(tracker.resumeSent(surfaceId: surface, token: token) == nil)
        #expect(tracker.totalResumes(surfaceId: surface) == 0)
    }

    @Test func theSameSessionStartingAgainKeepsTheMarkerCount() {
        // Claude Code re-sends SessionStart after a compact or resume. The
        // agent has not finished a turn yet, so the marker must stay.
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported,
            surfaceId: surface,
            isSubagent: false,
            detail: "overloaded",
            sessionId: "session-a"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        _ = tracker.resumeSent(surfaceId: surface, token: token)
        _ = tracker.observe(kind: .sessionStarted, surfaceId: surface, isSubagent: false, detail: nil, sessionId: "session-a")
        #expect(tracker.totalResumes(surfaceId: surface) == 1)
    }

    @Test func anErrorNamingTheSessionForTheFirstTimeKeepsTheMarkerCount() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1), .seconds(2)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        _ = tracker.resumeSent(surfaceId: surface, token: token)
        guard case .schedule(_, 2, _, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded", sessionId: "session-a"
        ) else {
            Issue.record("the streak should continue at attempt 2")
            return
        }
        #expect(tracker.totalResumes(surfaceId: surface) == 1)
    }

    @Test func aLateErrorFromAnOlderSessionCannotReplaceTheCurrentSession() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        _ = tracker.observe(
            kind: .sessionStarted,
            surfaceId: surface,
            isSubagent: false,
            detail: nil,
            sessionId: "session-b"
        )
        #expect(
            tracker.observe(
                kind: .errorReported,
                surfaceId: surface,
                isSubagent: false,
                detail: "overloaded",
                sessionId: "session-a"
            ) == .none
        )
        #expect(tracker.totalResumes(surfaceId: surface) == 0)
    }

    @Test(arguments: [
        AgentJournalEventKind.turnCompleted,
        .turnStarted,
        .approvalRequested,
        .questionRequested,
        .planReviewRequested,
        .attentionResolved,
        .sessionEnded,
    ])
    func lateLifecycleEventsFromAnOlderSessionCannotCancelTheCurrentResume(kind: AgentJournalEventKind) {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        _ = tracker.observe(
            kind: .sessionStarted,
            surfaceId: surface,
            isSubagent: false,
            detail: nil,
            sessionId: "session-current"
        )
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported,
            surfaceId: surface,
            isSubagent: false,
            detail: "overloaded",
            sessionId: "session-current"
        ) else {
            Issue.record("expected a schedule")
            return
        }

        #expect(
            tracker.observe(
                kind: kind,
                surfaceId: surface,
                isSubagent: false,
                detail: nil,
                sessionId: "session-old"
            ) == .none
        )
        #expect(tracker.isPending(surfaceId: surface, token: token))
    }

    @Test func explicitInputCancelsAndResetsTheFailingStreak() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1), .seconds(2)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }

        #expect(tracker.explicitInput(surfaceId: surface) == .cancel(surfaceId: surface))
        #expect(tracker.resumeSent(surfaceId: surface, token: token) == nil)
        guard case .schedule(_, 1, _, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("explicit input should reset the failing streak")
            return
        }
    }

    @Test func permanentFailuresAndSubagentsNeverSchedule() {
        var tracker = AgentAutoResumeTracker()
        #expect(tracker.observe(kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "authentication_failed") == .none)
        #expect(tracker.observe(kind: .errorReported, surfaceId: surface, isSubagent: true, detail: "overloaded") == .none)
        #expect(tracker.totalResumes(surfaceId: surface) == 0)
    }
}

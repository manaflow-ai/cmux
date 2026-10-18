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
        guard case .schedule(_, 1, _, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("a new streak should start at attempt 1")
            return
        }
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

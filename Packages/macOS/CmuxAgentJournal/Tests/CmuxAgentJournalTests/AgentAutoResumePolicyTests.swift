import Testing
@testable import CmuxAgentJournal

@Suite("Agent auto-resume policy")
struct AgentAutoResumePolicyTests {
    private let surface = "5B1E1B8E-0C0A-4C8C-9A55-2C5B1F0D1A01"

    @Test(arguments: [
        "overloaded: Overloaded",
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

    @Test func aCompletedTurnResetsTheStreakButKeepsTheTotal() {
        var tracker = AgentAutoResumeTracker(delays: [.seconds(1)])
        guard case let .schedule(_, _, _, token) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("expected a schedule")
            return
        }
        _ = tracker.resumeSent(surfaceId: surface, token: token)
        #expect(tracker.observe(kind: .turnCompleted, surfaceId: surface, isSubagent: false, detail: nil) == .none)
        guard case .schedule(_, 1, _, _) = tracker.observe(
            kind: .errorReported, surfaceId: surface, isSubagent: false, detail: "overloaded"
        ) else {
            Issue.record("a new streak should start at attempt 1")
            return
        }
        #expect(tracker.totalResumes(surfaceId: surface) == 1)
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

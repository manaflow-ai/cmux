import CMUXAgentLaunch
import Testing

/// Claude Code fires `StopFailure` instead of `Stop` when a turn dies on an
/// API error. cmux classifies the payload so the sidebar can show why the
/// session stopped instead of leaving it "Running".
@Suite("Claude StopFailure classification")
struct ClaudeStopFailureTests {
    private func failure(
        errorType: String?,
        message: String?,
        event: String = "StopFailure"
    ) -> ClaudeStopFailure? {
        var payload: [String: Any] = [
            "hook_event_name": event,
            "session_id": "session-1",
        ]
        if let errorType { payload["error"] = errorType }
        if let message { payload["last_assistant_message"] = message }
        return ClaudeStopFailure(hookPayload: payload)
    }

    @Test("Only StopFailure payloads classify")
    func onlyStopFailure() {
        #expect(failure(errorType: "rate_limit", message: "limit", event: "Stop") == nil)
        #expect(ClaudeStopFailure(hookPayload: ["error": "rate_limit"]) == nil)
        #expect(ClaudeStopFailure(hookPayload: nil) == nil)
        #expect(failure(errorType: nil, message: nil, event: "stop_failure")?.reason == .apiError)
        #expect(ClaudeStopFailure.isStopFailureEvent("StopFailure"))
        #expect(!ClaudeStopFailure.isStopFailureEvent("Stop"))
    }

    @Test("Usage limit keeps its reset time")
    func usageLimitResetTime() {
        let weekly = failure(
            errorType: "rate_limit",
            message: "You've hit your weekly limit · resets Oct 3 at 9am (America/Toronto)"
        )
        #expect(weekly?.reason == .usageLimit)
        #expect(weekly?.resetsAt == "Oct 3 at 9am")

        let hourly = failure(
            errorType: "rate_limit",
            message: "5-hour limit reached ∙ resets 3pm (America/New_York)"
        )
        #expect(hourly?.reason == .usageLimit)
        #expect(hourly?.resetsAt == "3pm")

        let noReset = failure(errorType: "rate_limit", message: "You've hit your usage limit")
        #expect(noReset?.reason == .usageLimit)
        #expect(noReset?.resetsAt == nil)
    }

    @Test("A plain rate limit is not a usage limit")
    func plainRateLimit() {
        let result = failure(errorType: "rate_limit", message: "Rate limited, please retry")
        #expect(result?.reason == .rateLimited)
        #expect(result?.resetsAt == nil)
        #expect(failure(errorType: "rate_limit", message: "API Error: Rate limit reached")?.reason == .rateLimited)
        // Claude Code 2.1.283's rendering of an API 429.
        #expect(
            failure(
                errorType: "rate_limit",
                message: "API Error: Request rejected (429) · Number of request tokens has exceeded your per-minute rate limit"
            )?.reason == .rateLimited
        )
    }

    @Test("Dropped connections classify from the message")
    func connectionDropped() {
        #expect(
            failure(errorType: "server_error", message: "API Error: Connection dropped (ECONNRESET)")?.reason
                == .connectionDropped
        )
        #expect(
            failure(
                errorType: "server_error",
                message: "API Error: Connection lost mid-response. The response above may be incomplete."
            )?.reason == .connectionDropped
        )
        #expect(failure(errorType: "unknown", message: "socket hang up")?.reason == .connectionDropped)
        #expect(failure(errorType: "server_error", message: "Internal server error")?.reason == .apiError)
    }

    @Test("Structured error types map directly")
    func structuredTypes() {
        #expect(failure(errorType: "overloaded", message: nil)?.reason == .overloaded)
        #expect(failure(errorType: "authentication_failed", message: nil)?.reason == .authentication)
        #expect(failure(errorType: "account_on_hold", message: nil)?.reason == .authentication)
        #expect(failure(errorType: "billing_error", message: nil)?.reason == .billing)
        #expect(failure(errorType: "max_output_tokens", message: nil)?.reason == .outputLimit)
        #expect(failure(errorType: "unknown", message: "API Error: 529 overloaded")?.reason == .overloaded)
        // Claude Code 2.1.283 reports a 529 as server_error.
        #expect(
            failure(
                errorType: "server_error",
                message: "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment."
            )?.reason == .overloaded
        )
    }

    @Test("The message is the rendered error text on one line")
    func messageSingleLine() {
        let result = ClaudeStopFailure(hookPayload: [
            "hook_event_name": "StopFailure",
            "error": "server_error",
            "error_details": "socket closed",
            "last_assistant_message": "API Error:\n  Connection dropped (ECONNRESET)",
        ])
        #expect(result?.reason == .connectionDropped)
        #expect(result?.message == "API Error: Connection dropped (ECONNRESET)")
    }

    @Test("The error type never becomes the message")
    func errorTypeIsNotTheMessage() {
        let result = ClaudeStopFailure(hookPayload: [
            "hook_event_name": "StopFailure",
            "error": "overloaded",
        ])
        #expect(result?.reason == .overloaded)
        #expect(result?.message == nil)
        let details = ClaudeStopFailure(hookPayload: [
            "hook_event_name": "StopFailure",
            "error": "server_error",
            "error_details": "500 Internal Server Error",
        ])
        #expect(details?.message == "500 Internal Server Error")
    }
}

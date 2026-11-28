import Testing
@testable import CmuxMobileAgentChat

/// The phone reads an upstream error as the Mac does: the same 12 rows as
/// `cmux-tui/crates/cmux-upstream-error` (`capacity_account_limit_and_retry_after_matrix`).
@Suite struct UpstreamErrorTests {
    static let matrix: [(message: String, capacity: Bool, limit: Bool, wait: Int?)] = [
        (#"API Error: 529 {"type":"overloaded_error"}"#, true, false, nil),
        ("HTTP 529 overloaded_error; retry-after: 30", true, false, 30),
        ("API error: 503 no non-exhausted accounts; retry after 3596s", true, false, 3596),
        ("503 Service Unavailable", true, false, nil),
        ("502 the gateway is at its call limit; retry", true, false, nil),
        ("Selected model is at capacity", true, false, nil),
        (#"{"code":529,"reason":"overloaded"}"#, true, false, nil),
        (#"{"error":{"type":"overloaded_error"},"retry_after":12}"#, true, false, 12),
        ("API Error: 429 rate_limit_error", false, true, nil),
        ("Too Many Requests; retry-after 90", false, true, 90),
        ("waited 2503s for the build", false, false, nil),
        ("API Error: 400 invalid_request_error", false, false, nil),
    ]

    @Test func capacityAccountLimitAndRetryAfterMatrix() {
        #expect(Self.matrix.count == 12)
        for row in Self.matrix {
            #expect(UpstreamError.isCapacity(row.message) == row.capacity, "isCapacity(\(row.message))")
            #expect(UpstreamError.isAccountLimit(row.message) == row.limit, "isAccountLimit(\(row.message))")
            #expect(UpstreamError.retryAfter(row.message) == row.wait, "retryAfter(\(row.message))")
        }
    }

    @Test func aStatusIsANumberOfItsOwn() {
        #expect(UpstreamError.hasStatus("http 503 unavailable", "503"))
        #expect(!UpstreamError.hasStatus("took 2503s", "503"))
        #expect(!UpstreamError.hasStatus("id 5290", "529"))
    }

    /// Every row the vocabulary calls capacity or an account limit is the card's "rate limited or out of
    /// capacity"; the rest are not.
    @Test func theCardFollowsTheMatrix() {
        for row in Self.matrix {
            let kind = TurnFailureCopy(message: row.message).kind
            #expect((kind == .rateLimited) == (row.capacity || row.limit), "\(row.message): \(kind)")
        }
        // Before: the worker gateway's ceiling read as an unknown error, its raw text as the sentence.
        let callLimit = TurnFailureCopy(message: "502 the gateway is at its call limit; retry", harness: "claude", harnessName: "Claude")
        #expect(callLimit.kind == .rateLimited)
        #expect(callLimit.sentence == "Claude is rate limited or out of capacity. Try again in a moment, or switch model.")
        #expect(callLimit.detail == "502 the gateway is at its call limit; retry")
        // The phone's own extras still read as rate limited.
        for message in ["rate-limited by upstream", "usage limit reached", "quota exceeded", "Service Unavailable"] {
            #expect(TurnFailureCopy(message: message).kind == .rateLimited, "\(message)")
        }
    }
}

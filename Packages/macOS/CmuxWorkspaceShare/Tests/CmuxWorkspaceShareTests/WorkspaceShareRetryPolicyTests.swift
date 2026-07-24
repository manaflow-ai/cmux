@testable import CmuxWorkspaceShare
import Testing

@Suite
struct WorkspaceShareRetryPolicyTests {
    private let policy = WorkspaceShareRetryPolicy()

    @Test(arguments: [
        WorkspaceShareSessionLifecycle.Failure.transport,
        .http(statusCode: 408, retryAfter: nil),
        .http(statusCode: 429, retryAfter: nil),
        .http(statusCode: 500, retryAfter: nil),
        .http(statusCode: 503, retryAfter: nil),
        .webSocketClosed(code: 1001, reason: nil),
        .webSocketClosed(code: 1005, reason: nil),
        .webSocketClosed(code: 1006, reason: nil),
        .webSocketClosed(code: 1011, reason: nil),
        .webSocketClosed(code: 1015, reason: nil),
        .webSocketClosed(code: 4008, reason: nil),
        .webSocketClosed(code: 4429, reason: nil),
    ])
    func `Transient failures retry`(_ failure: WorkspaceShareSessionLifecycle.Failure) {
        #expect(
            policy.decision(for: failure, attempt: 0, randomUnitInterval: 0)
                == .retry(after: .milliseconds(500))
        )
    }

    @Test(arguments: [
        WorkspaceShareSessionLifecycle.Failure.http(statusCode: 400, retryAfter: nil),
        .http(statusCode: 401, retryAfter: nil),
        .http(statusCode: 403, retryAfter: nil),
        .http(statusCode: 404, retryAfter: nil),
        .webSocketClosed(code: 1000, reason: nil),
        .webSocketClosed(code: 1002, reason: nil),
        .webSocketClosed(code: 1008, reason: nil),
        .webSocketClosed(code: 1009, reason: nil),
        .webSocketClosed(code: 4400, reason: nil),
        .webSocketClosed(code: 1011, reason: "delivery_failed"),
        .webSocketClosed(code: 1011, reason: "server_message_too_large"),
        .invalidEndpoint,
        .cancelled,
    ])
    func `Permanent failures stop`(_ failure: WorkspaceShareSessionLifecycle.Failure) {
        #expect(
            policy.decision(for: failure, attempt: 0, randomUnitInterval: 0)
                == .stop
        )
    }

    @Test
    func `Backoff is exponential capped and deterministically jittered`() {
        #expect(
            policy.decision(for: .transport, attempt: 0, randomUnitInterval: 0)
                == .retry(after: .milliseconds(500))
        )
        #expect(
            policy.decision(for: .transport, attempt: 0, randomUnitInterval: 1)
                == .retry(after: .milliseconds(625))
        )
        #expect(
            policy.decision(for: .transport, attempt: 1, randomUnitInterval: 0)
                == .retry(after: .seconds(1))
        )
        #expect(
            policy.decision(for: .transport, attempt: 99, randomUnitInterval: 1)
                == .retry(after: .milliseconds(37_500))
        )
    }

    @Test
    func `Retry After is a floor only for retryable responses`() {
        #expect(
            policy.decision(
                for: .http(statusCode: 429, retryAfter: .seconds(20)),
                attempt: 0,
                randomUnitInterval: 1
            ) == .retry(after: .seconds(20))
        )
        #expect(
            policy.decision(
                for: .http(statusCode: 503, retryAfter: .milliseconds(100)),
                attempt: 0,
                randomUnitInterval: 1
            ) == .retry(after: .milliseconds(625))
        )
        #expect(
            policy.decision(
                for: .http(statusCode: 403, retryAfter: .seconds(60)),
                attempt: 0,
                randomUnitInterval: 0
            ) == .stop
        )
    }
}

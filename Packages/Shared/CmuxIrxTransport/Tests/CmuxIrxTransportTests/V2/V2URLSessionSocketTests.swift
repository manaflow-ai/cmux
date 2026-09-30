import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite
struct V2URLSessionSocketTests {
    enum Outcome: Sendable {
        case pong, aborted, disconnected

        var error: (any Error)? {
            switch self {
            case .pong: nil
            case .aborted: POSIXError(.ECONNABORTED)
            case .disconnected: URLError(.networkConnectionLost)
            }
        }
    }

    @Test(arguments: [
        [Outcome.pong, .aborted],
        [.aborted, .pong],
        [.aborted, .disconnected],
        [.pong, .pong],
    ])
    func duplicateCallbacksPreserveFirstResult(outcomes: [Outcome]) async throws {
        do {
            try await V2URLSessionSocket.ping { completion in
                for outcome in outcomes { completion(outcome.error) }
            }
            #expect(outcomes.first == .pong)
        } catch {
            let expected = try #require(outcomes.first?.error) as NSError
            #expect((error as NSError).domain == expected.domain)
            #expect((error as NSError).code == expected.code)
        }
    }

    @Test(arguments: [Outcome.pong, .aborted])
    func concurrentCallbacksCompleteOnce(outcome: Outcome) async throws {
        do {
            try await V2URLSessionSocket.ping { completion in
                DispatchQueue.concurrentPerform(iterations: 32) { _ in
                    completion(outcome.error)
                }
            }
            #expect(outcome == .pong)
        } catch {
            let expected = try #require(outcome.error) as NSError
            #expect((error as NSError).domain == expected.domain)
            #expect((error as NSError).code == expected.code)
        }
    }

    @Test func lateCallbackDoesNotAffectNextPing() async throws {
        let callbacks = AsyncStream<@Sendable ((any Error)?) -> Void>.makeStream()
        defer { callbacks.continuation.finish() }
        var iterator = callbacks.stream.makeAsyncIterator()

        let firstPing = Task {
            try await V2URLSessionSocket.ping { callbacks.continuation.yield($0) }
        }
        let firstCompletion = try #require(await iterator.next())
        firstCompletion(nil)
        try await firstPing.value

        let secondPing = Task {
            try await V2URLSessionSocket.ping { callbacks.continuation.yield($0) }
        }
        let secondCompletion = try #require(await iterator.next())
        firstCompletion(POSIXError(.ECONNABORTED))
        secondCompletion(nil)
        try await secondPing.value
    }
}

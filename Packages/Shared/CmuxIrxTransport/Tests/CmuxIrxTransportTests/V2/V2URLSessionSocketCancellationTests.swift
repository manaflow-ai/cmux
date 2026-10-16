import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite("V2 URLSession socket cancellation")
struct V2URLSessionSocketCancellationTests {
    @Test("cancellation wins when the URLSession callback arrives afterwards")
    func cancellationCompletesBeforeLateCallback() async throws {
        let callbacks = AsyncStream<@Sendable ((any Error)?) -> Void>.makeStream()
        defer { callbacks.continuation.finish() }
        var iterator = callbacks.stream.makeAsyncIterator()

        let ping = Task {
            try await V2URLSessionSocket.ping { callbacks.continuation.yield($0) }
        }
        let completion = try #require(await iterator.next())

        ping.cancel()
        completion(nil)

        do {
            try await ping.value
            Issue.record("a cancelled ping must not be completed by a late success callback")
        } catch is CancellationError {
            // Expected: cancellation owns the one completion.
        }
    }
}

internal import Foundation

final class AnalyticsUploadStartGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
    }

    func wait() async {
        for await _ in stream { return }
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }
}

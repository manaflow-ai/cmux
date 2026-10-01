import Foundation

/// A controllable event lane shared by independent-event integration tests.
actor IndependentEventSource {
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?

    func makeStream() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
        }
    }

    func yield(_ data: Data) {
        continuation?.yield(data)
    }

    func finish(throwing error: any Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}


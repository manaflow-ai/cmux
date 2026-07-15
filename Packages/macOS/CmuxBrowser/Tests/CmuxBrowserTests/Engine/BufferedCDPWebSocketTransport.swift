import Foundation
@testable import CmuxBrowser

actor BufferedCDPWebSocketTransport: CDPWebSocketTransport {
    private var bufferedData: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data, any Error>?
    private var receiveCount = 0
    private var receiveCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated func resume() {}

    func send(_: Data) async throws {}

    func receive() async throws -> Data {
        receiveCount += 1
        resumeReceiveCountWaiters()
        if !bufferedData.isEmpty {
            return bufferedData.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    nonisolated func cancel() {
        Task {
            await finish()
        }
    }

    func deliverAndWaitUntilConsumed(_ data: Data) async {
        let nextReceiveCount = receiveCount + 1
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: data)
        } else {
            bufferedData.append(data)
        }
        guard receiveCount < nextReceiveCount else { return }
        await withCheckedContinuation { continuation in
            receiveCountWaiters.append((nextReceiveCount, continuation))
        }
    }

    private func finish() {
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    private func resumeReceiveCountWaiters() {
        let ready = receiveCountWaiters.filter { $0.count <= receiveCount }
        receiveCountWaiters.removeAll { $0.count <= receiveCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

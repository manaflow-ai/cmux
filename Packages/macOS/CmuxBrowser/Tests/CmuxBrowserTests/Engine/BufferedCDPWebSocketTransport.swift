import Foundation
@testable import CmuxBrowser

actor BufferedCDPWebSocketTransport: CDPWebSocketTransport {
    private var bufferedData: [Data] = []
    private var sentData: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data, any Error>?
    private var receiveCount = 0
    private var receiveCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated func resume() {}

    func send(_ data: Data) async throws {
        sentData.append(data)
    }

    func sentCommandCount(method: String) -> Int {
        sentData.reduce(into: 0) { count, data in
            guard let payload = try? JSONDecoder().decode(
                [String: CDPJSONValue].self,
                from: data
            ), payload["method"] == .string(method) else { return }
            count += 1
        }
    }

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
        let waiters = receiveCountWaiters
        receiveCountWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func resumeReceiveCountWaiters() {
        let ready = receiveCountWaiters.filter { $0.count <= receiveCount }
        receiveCountWaiters.removeAll { $0.count <= receiveCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

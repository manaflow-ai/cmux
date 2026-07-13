import CMUXMobileCore
import Foundation

actor StalledWriteTransport: CmxByteTransport {
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sendWaiter = continuation
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func failStalledSend() {
        sendWaiter?.resume(throwing: CancellationError())
        sendWaiter = nil
    }

    func closed() -> Bool {
        isClosed
    }
}

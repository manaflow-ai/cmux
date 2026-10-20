import CMUXMobileCore
import Foundation

actor StalledWriteTransport: CmxByteTransport {
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var sendStarted = false
    private var sendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private let hangsOnClose: Bool
    private var closeRelease: CheckedContinuation<Void, Never>?
    private var closeReleased = false

    init(hangsOnClose: Bool = false) {
        self.hangsOnClose = hangsOnClose
    }

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
        sendStarted = true
        for waiter in sendStartWaiters { waiter.resume() }
        sendStartWaiters = []
        try await withCheckedThrowingContinuation { continuation in
            sendWaiter = continuation
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        for waiter in closeStartWaiters { waiter.resume() }
        closeStartWaiters = []
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        guard hangsOnClose, !closeReleased else { return }
        await withCheckedContinuation { closeRelease = $0 }
    }

    func failStalledSend() {
        sendWaiter?.resume(throwing: CancellationError())
        sendWaiter = nil
    }

    func closed() -> Bool {
        isClosed
    }

    func waitUntilSendStarted() async {
        if sendStarted { return }
        await withCheckedContinuation { sendStartWaiters.append($0) }
    }

    func waitUntilCloseStarted() async {
        if isClosed { return }
        await withCheckedContinuation { closeStartWaiters.append($0) }
    }

    func releaseClose() {
        closeReleased = true
        closeRelease?.resume()
        closeRelease = nil
    }
}

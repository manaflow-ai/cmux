import CMUXMobileCore
import Foundation

actor TransportDrainProbe: CmxByteTransport {
    private var sendStarted = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeStarted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleased = false
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}

    func receive() async throws -> Data? {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }

    func send(_ data: Data) async throws {
        _ = data
        sendStarted = true
        for waiter in sendWaiters { waiter.resume() }
        sendWaiters = []
    }

    func close() async {
        closeStarted = true
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters = []
        guard !closeReleased else { return }
        await withCheckedContinuation {
            closeReleaseWaiters.append($0)
        }
    }

    func waitUntilSendStarted() async {
        if sendStarted { return }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }
}

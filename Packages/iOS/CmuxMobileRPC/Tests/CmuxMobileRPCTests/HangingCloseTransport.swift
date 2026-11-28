import CMUXMobileCore
import Foundation

actor HangingCloseTransport: CmxByteTransport {
    private var closeStarted = false
    private var closeReleased = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {
        closeStarted = true
        for waiter in closeStartWaiters { waiter.resume() }
        closeStartWaiters = []
        guard !closeReleased else { return }
        await withCheckedContinuation { closeReleaseWaiters.append($0) }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation { closeStartWaiters.append($0) }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }
}

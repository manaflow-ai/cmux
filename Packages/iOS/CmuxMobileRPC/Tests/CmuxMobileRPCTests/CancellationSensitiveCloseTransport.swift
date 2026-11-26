import CMUXMobileCore
import Foundation

actor CancellationSensitiveCloseTransport: CmxByteTransport {
    private var closeStarted = false
    private var closeReleased = false
    private var closeObservedCancellation = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}

    func close() async {
        closeStarted = true
        for waiter in closeStartWaiters { waiter.resume() }
        closeStartWaiters = []
        guard !closeReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                closeReleaseWaiters.append($0)
            }
        } onCancel: {
            Task { await self.cancelClose() }
        }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation { closeStartWaiters.append($0) }
    }

    func didObserveCloseCancellation() -> Bool {
        closeObservedCancellation
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }

    private func cancelClose() {
        closeObservedCancellation = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }
}

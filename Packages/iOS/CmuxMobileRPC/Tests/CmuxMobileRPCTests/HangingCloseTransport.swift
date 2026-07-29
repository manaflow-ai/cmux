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

actor CancellationSensitiveCloseTransport: CmxByteTransport {
    private var closeStarted = false
    private var closeReleased = false
    private var closeObservedCancellation = false
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

/// Cancellation starts a close that releases `connect()` immediately but can
/// keep physical cleanup suspended afterward.
actor CancellationThrowingConnectHangingCloseTransport:
    CmxByteTransport {
    private var connectStarted = false
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var closeStarted = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleased = false
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        connectStarted = true
        for waiter in connectStartWaiters { waiter.resume() }
        connectStartWaiters = []
        await withCheckedContinuation {
            connectWaiter = $0
        }
        throw CancellationError()
    }

    func receive() async throws -> Data? { nil }

    func send(_: Data) async throws {}

    func close() async {
        closeStarted = true
        for waiter in closeStartWaiters { waiter.resume() }
        closeStartWaiters = []
        connectWaiter?.resume()
        connectWaiter = nil
        guard !closeReleased else { return }
        await withCheckedContinuation {
            closeReleaseWaiters.append($0)
        }
    }

    func waitUntilConnectStarted() async {
        if connectStarted { return }
        await withCheckedContinuation {
            connectStartWaiters.append($0)
        }
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation {
            closeStartWaiters.append($0)
        }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters { waiter.resume() }
        closeReleaseWaiters = []
    }
}

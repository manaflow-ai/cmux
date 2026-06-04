import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the network-recovery state machine carved into
/// ``MobileRecoveryCoordinator``: live connections resync instead of
/// reconnecting, dropped connections reconnect once per trigger burst, a
/// failed reconnect surfaces the Retry control, and manual Retry clears it.
@MainActor
@Suite struct MobileRecoveryCoordinatorTests {
    @Test func pathChangeWhileConnectedResyncsWithoutReconnecting() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.hasLiveRemoteConnection = true
        context.isConnected = true
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.startObservingNetworkPathChanges()

        await reachability.yieldPathChange()
        try await waitUntil { context.resyncs.count == 1 }

        #expect(context.reconnectingMarks == 1)
        #expect(context.resyncs.first?.reason == "networkRecovery.networkChange")
        #expect(context.resyncs.first?.restartEventStream == true)
        #expect(context.reconnectStackUserIDs.isEmpty)
        #expect(!coordinator.isRecoveringConnection)
    }

    @Test func pathChangeWhileDisconnectedReconnectsWithPreparedStackUser() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.reconnectResult = true
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.prepareForReconnect(stackUserID: "stack-user-1")

        await reachability.yieldPathChange()
        try await waitUntil { context.reconnectStackUserIDs.count == 1 }
        try await waitUntil { !coordinator.isRecoveringConnection }

        #expect(context.reconnectStackUserIDs == ["stack-user-1"])
        #expect(!coordinator.connectionRecoveryFailed)
    }

    @Test func failedReconnectSurfacesRetryControl() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.reconnectResult = false
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.prepareForReconnect(stackUserID: nil)

        await reachability.yieldPathChange()
        try await waitUntil { coordinator.connectionRecoveryFailed }

        #expect(!coordinator.isRecoveringConnection)
        #expect(context.reconnectStackUserIDs.count == 1)
    }

    @Test func manualRetryClearsFailureAndReconnects() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.reconnectResult = false
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.prepareForReconnect(stackUserID: nil)
        await reachability.yieldPathChange()
        try await waitUntil { coordinator.connectionRecoveryFailed }

        context.reconnectResult = true
        coordinator.retryMobileConnection()
        try await waitUntil { context.reconnectStackUserIDs.count == 2 }
        try await waitUntil { !coordinator.isRecoveringConnection }

        #expect(!coordinator.connectionRecoveryFailed)
    }

    @Test func overlappingTriggersCoalesceIntoOneInFlightReconnect() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.reconnectResult = true
        context.holdReconnects = true
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.prepareForReconnect(stackUserID: nil)

        await reachability.yieldPathChange()
        try await waitUntil { context.reconnectStackUserIDs.count == 1 }
        // Second trigger lands while the first reconnect is still in flight.
        await reachability.yieldPathChange()
        coordinator.retryMobileConnection()
        context.releaseHeldReconnects()
        try await waitUntil { !coordinator.isRecoveringConnection }

        #expect(context.reconnectStackUserIDs.count == 1)
    }

    @Test func recoveryWithNothingToRecoverIsANoOp() async throws {
        let reachability = ScriptedReachability()
        let context = RecoveryContextDouble()
        context.canAttemptRecovery = false
        let coordinator = MobileRecoveryCoordinator(reachability: reachability)
        coordinator.bind(context: context)
        coordinator.startObservingNetworkPathChanges()

        await reachability.yieldPathChange()
        coordinator.retryMobileConnection()
        // Give the observation loop a chance to (incorrectly) act.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(context.reconnectStackUserIDs.isEmpty)
        #expect(context.resyncs.isEmpty)
        #expect(!coordinator.isRecoveringConnection)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}

/// Scripted ``ReachabilityProviding`` whose path-change stream is driven by
/// the test.
final class ScriptedReachability: ReachabilityProviding, @unchecked Sendable {
    // All mutation happens through the actor below; the class only exists to
    // satisfy the protocol's Sendable requirement with a stable identity.
    private let state = State()

    var isOnline: Bool {
        get async { true }
    }

    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task { await state.register(continuation) }
        }
    }

    /// Yields one path change to every observer, waiting for at least one
    /// observer to be registered first so a yield can never race the
    /// coordinator's stream subscription.
    func yieldPathChange() async {
        await state.yieldToAll()
    }

    private actor State {
        private var continuations: [AsyncStream<Void>.Continuation] = []
        private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

        func register(_ continuation: AsyncStream<Void>.Continuation) {
            continuations.append(continuation)
            let waiters = registrationWaiters
            registrationWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }

        func yieldToAll() async {
            if continuations.isEmpty {
                await withCheckedContinuation { continuation in
                    registrationWaiters.append(continuation)
                }
            }
            for continuation in continuations {
                continuation.yield(())
            }
        }
    }
}

/// Scripted ``MobileConnectionRecoveryContext`` recording every interaction.
@MainActor
final class RecoveryContextDouble: MobileConnectionRecoveryContext {
    var canAttemptRecovery = true
    var hasLiveRemoteConnection = false
    var isConnected = false
    var reconnectResult = false
    var holdReconnects = false

    private(set) var reconnectingMarks = 0
    private(set) var resyncs: [(reason: String, restartEventStream: Bool)] = []
    private(set) var reconnectStackUserIDs: [String?] = []
    private var heldReconnects: [CheckedContinuation<Void, Never>] = []

    func markMacConnectionReconnecting() {
        reconnectingMarks += 1
    }

    func resyncTerminalOutput(reason: String, restartEventStream: Bool) {
        resyncs.append((reason, restartEventStream))
    }

    @discardableResult
    func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        reconnectStackUserIDs.append(stackUserID)
        if holdReconnects {
            await withCheckedContinuation { continuation in
                heldReconnects.append(continuation)
            }
        }
        return reconnectResult
    }

    func releaseHeldReconnects() {
        let held = heldReconnects
        heldReconnects = []
        for continuation in held {
            continuation.resume()
        }
    }
}

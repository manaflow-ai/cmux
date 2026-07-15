import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileFirstConnectionPresentationTests {
    @Test func manualPairingRequiresAnAuthoritativeEmptyRegistry() {
        #expect(MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: false)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: true,
            registryState: .loaded(hasAccountSession: false)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: true)
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loading
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .authRejected
        ).shouldPresentManualPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .unavailable
        ).shouldPresentManualPairing)
    }

    @Test func automaticPairingDismissesOnlyForAuthoritativeReplacement() {
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loading
        ).shouldDismissAutomaticPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .unavailable
        ).shouldDismissAutomaticPairing)
        #expect(!MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: false)
        ).shouldDismissAutomaticPairing)
        #expect(MobileFirstConnectionState(
            hasSavedComputer: true,
            registryState: .unavailable
        ).shouldDismissAutomaticPairing)
        #expect(MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .loaded(hasAccountSession: true)
        ).shouldDismissAutomaticPairing)
        #expect(MobileFirstConnectionState(
            hasSavedComputer: false,
            registryState: .authRejected
        ).shouldDismissAutomaticPairing)
    }

    @Test func savedComputerAndHandoffConnectionsShareOneAttemptGate() {
        #expect(MobileFirstConnectionAttemptState(
            connectingSavedComputerID: nil,
            pendingHandoffID: nil
        ).canStartConnection)
        #expect(!MobileFirstConnectionAttemptState(
            connectingSavedComputerID: "mac-a",
            pendingHandoffID: nil
        ).canStartConnection)
        #expect(!MobileFirstConnectionAttemptState(
            connectingSavedComputerID: nil,
            pendingHandoffID: "session-a"
        ).canStartConnection)
    }

    @Test func registryRefreshesBeforeLiveSessionLeaseExpires() {
        let policy = MobileFirstConnectionRegistryRefreshPolicy()

        #expect(policy.refreshInterval == .seconds(40))
        #expect(policy.refreshInterval < .seconds(120))
    }

    @MainActor
    @Test func registryRenewalUsesAnIndependentCancellableClock() async {
        let clock = RegistryRefreshTestClock()
        let recorder = RegistryRefreshRecorder()
        let loop = MobileFirstConnectionRegistryRefreshLoop(
            policy: MobileFirstConnectionRegistryRefreshPolicy(refreshInterval: .seconds(40))
        )
        let task = Task { @MainActor in
            await loop.run(
                clock: clock,
                whileCurrent: { true },
                refresh: { await recorder.record() }
            )
        }

        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: .seconds(39))
        await Task.yield()
        #expect(await recorder.count == 0)

        clock.advance(by: .seconds(1))
        await recorder.waitUntilCount(1)
        await clock.waitUntilSleepers(count: 1)

        task.cancel()
        await task.value
        clock.advance(by: .seconds(40))
        #expect(await recorder.count == 1)
    }

    @Test func discoveredSessionDismissesOnlyAutomaticPairing() {
        var automatic = MobileAddDevicePresentationState()
        automatic.present(origin: .automaticFirstConnection)
        automatic.dismissAutomaticForAvailableSession()
        #expect(!automatic.isPresented)

        var userInitiated = MobileAddDevicePresentationState()
        userInitiated.present(origin: .userInitiated)
        userInitiated.dismissAutomaticForAvailableSession()
        #expect(userInitiated.isPresented)

        var attachApproval = MobileAddDevicePresentationState()
        attachApproval.present(origin: .attachTicketApproval)
        attachApproval.dismissAutomaticForAvailableSession()
        #expect(attachApproval.isPresented)
    }

    @Test func automaticPairingNeverTakesOverAnExistingPresentation() {
        var unowned = MobileAddDevicePresentationState()
        unowned.presentAutomaticallyIfUnowned()
        #expect(unowned.origin == .automaticFirstConnection)

        var userInitiated = MobileAddDevicePresentationState(origin: .userInitiated)
        userInitiated.presentAutomaticallyIfUnowned()
        #expect(userInitiated.origin == .userInitiated)

        var attachApproval = MobileAddDevicePresentationState(origin: .attachTicketApproval)
        attachApproval.presentAutomaticallyIfUnowned()
        #expect(attachApproval.origin == .attachTicketApproval)
    }

    @Test func meaningfulInteractionClaimsAnAutomaticPairingPresentation() {
        var presentation = MobileAddDevicePresentationState(origin: .automaticFirstConnection)

        presentation.claimAutomaticForUserInteraction()
        presentation.dismissAutomaticForAvailableSession()

        #expect(presentation.origin == .userInitiated)
        #expect(presentation.isPresented)
    }

    @Test func disappearingFirstConnectionScopeRejectsStaleRetryCompletion() {
        var scope = MobileFirstConnectionDiscoveryScope()
        let staleRequest = scope.activate("account-a")
        #expect(scope.isCurrent(staleRequest))

        scope.invalidate()
        _ = scope.activate("account-a")

        #expect(!scope.isCurrent(staleRequest))
    }
}

private actor RegistryRefreshRecorder {
    private(set) var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntilCount(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

private final class RegistryRefreshTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledSleeperIDs: Set<UUID> = []
    private var parkWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledSleeperIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                let ready = takeSatisfiedParkWaitersLocked()
                lock.unlock()
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil { cancelledSleeperIDs.insert(id) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleepers(count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepers.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            parkWaiters.append((count, continuation))
            lock.unlock()
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        let due = sleepers
            .filter { $0.value.deadline <= currentInstant }
            .sorted { $0.value.deadline < $1.value.deadline }
        due.forEach { sleepers[$0.key] = nil }
        lock.unlock()
        due.forEach { $0.value.continuation.resume() }
    }

    private func takeSatisfiedParkWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        parkWaiters.removeAll { waiter in
            guard sleepers.count >= waiter.count else { return false }
            ready.append(waiter.continuation)
            return true
        }
        return ready
    }
}

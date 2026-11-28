#if os(iOS)
@testable import CmuxMobileShellUI
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct OnboardingMacDiscoveryKeepAliveTests {
    private let accountA = OnboardingDiscoveryAccountKey(userID: "user-a", teamID: "team-a")

    @Test
    func startsAttemptWhenAuthorizedAndSearching() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        var attemptCount = 0

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptCount += 1
            return true
        }

        #expect(await eventually { attemptCount == 1 && !keepAlive.isRunning })
    }

    @Test
    func rearmsUntilAnAttemptConnectsAndReleasesCoordinatorClaim() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        var outcomes = [false, false, true]
        var attemptCount = 0

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptCount += 1
            return outcomes.isEmpty ? true : outcomes.removeFirst()
        }

        #expect(await eventually { attemptCount == 3 && !keepAlive.isRunning })
        let releasedClaim = try #require(coordinator.claimStoredReconnect())
        coordinator.finishStoredReconnect(releasedClaim)
    }

    @Test
    func connectedAttemptStopsWithoutRearming() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        var attemptCount = 0

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptCount += 1
            return true
        }

        #expect(await eventually { !keepAlive.isRunning })
        #expect(attemptCount == 1)
    }

    @Test
    func gracefulStopLetsInflightAttemptFinishWithoutRearming() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        let gate = AttemptParkingGate()
        var attemptCount = 0
        let attempt: @MainActor () async -> Bool = {
            attemptCount += 1
            return await gate.run()
        }

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )
        #expect(await eventually { gate.didStart })

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: false,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )
        gate.resume(returning: false)

        #expect(await eventually { !keepAlive.isRunning })
        #expect(!gate.cancellationObserved)
        #expect(attemptCount == 1)
    }

    @Test
    func deauthorizationHardCancelsInflightAttempt() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        let gate = AttemptParkingGate()
        let attempt: @MainActor () async -> Bool = {
            await gate.run()
        }

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )
        #expect(await eventually { gate.didStart })

        keepAlive.update(
            isDiscoveryAuthorized: false,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )

        #expect(await eventually { gate.cancellationObserved })
        #expect(!keepAlive.isRunning)
    }

    @Test
    func accountChangeCancelsOldAttemptAndStartsFreshLoop() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        let oldGate = AttemptParkingGate()
        let accountB = OnboardingDiscoveryAccountKey(userID: "user-b", teamID: "team-b")
        var attemptedAccounts: [OnboardingDiscoveryAccountKey] = []

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptedAccounts.append(accountA)
            return await oldGate.run()
        }
        #expect(await eventually { oldGate.didStart })

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountB,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptedAccounts.append(accountB)
            return true
        }

        #expect(await eventually {
            oldGate.cancellationObserved
                && attemptedAccounts == [accountA, accountB]
                && !keepAlive.isRunning
        })
    }

    @Test
    func waitsUntilCoordinatorOwnershipIsReleased() async throws {
        let coordinator = MobileStartupConnectionCoordinator()
        let externalClaim = try #require(coordinator.claimStoredReconnect())
        let clock = OnboardingDiscoveryManualClock()
        let keepAlive = makeKeepAlive(
            clock: clock,
            claimRetryDelay: .seconds(1)
        )
        var attemptCount = 0

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator
        ) {
            attemptCount += 1
            return true
        }

        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(attemptCount == 0)

        coordinator.finishStoredReconnect(externalClaim)
        clock.advance(by: .seconds(1))
        #expect(await eventually { attemptCount == 1 && !keepAlive.isRunning })
    }

    @Test
    func identicalUpdateDoesNotRestartParkedAttempt() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        let gate = AttemptParkingGate()
        var attemptCount = 0
        let attempt: @MainActor () async -> Bool = {
            attemptCount += 1
            return await gate.run()
        }

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )
        #expect(await eventually { gate.didStart })

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { true },
            coordinator: coordinator,
            runAttempt: attempt
        )
        #expect(!gate.cancellationObserved)

        gate.resume(returning: true)
        #expect(await eventually { !keepAlive.isRunning })
        #expect(attemptCount == 1)
    }

    @Test
    func lostEligibilityStopsRearmingWithoutAnUpdateCall() async {
        let coordinator = MobileStartupConnectionCoordinator()
        let keepAlive = makeKeepAlive()
        var eligible = true
        var attemptCount = 0

        keepAlive.update(
            isDiscoveryAuthorized: true,
            accountKey: accountA,
            shouldKeepSearching: true,
            isStillEligible: { eligible },
            coordinator: coordinator
        ) {
            attemptCount += 1
            // Simulates the connect page taking over (or the Mac connecting)
            // while no SwiftUI onChange push reaches update().
            eligible = false
            return false
        }

        #expect(await eventually { !keepAlive.isRunning })
        #expect(attemptCount == 1)
    }

    private func makeKeepAlive(
        clock: any Clock<Duration> = ContinuousClock(),
        claimRetryDelay: Duration = .milliseconds(1)
    ) -> OnboardingMacDiscoveryKeepAlive {
        OnboardingMacDiscoveryKeepAlive(
            clock: clock,
            retryDelay: .milliseconds(1),
            claimRetryDelay: claimRetryDelay
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

private final class OnboardingDiscoveryManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: UnsafeContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var preCancelledIDs: Set<UUID> = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<Void, any Error>) in
                lock.lock()
                if preCancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    ))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelSleeper(id: id)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers
            .filter { $0.deadline <= current }
            .sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(id: UUID) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
            preCancelledIDs.insert(id)
            lock.unlock()
            return
        }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class AttemptParkingGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var didStart = false
    private(set) var cancellationObserved = false

    func run() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                didStart = true
                if Task.isCancelled {
                    observeCancellation()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.observeCancellation()
            }
        }
    }

    func resume(returning result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func observeCancellation() {
        cancellationObserved = true
        resume(returning: false)
    }
}
#endif

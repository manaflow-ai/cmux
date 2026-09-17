#if os(iOS)
@testable import CmuxMobileShellUI
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
        try? await ContinuousClock().sleep(for: .milliseconds(20))
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
        try? await ContinuousClock().sleep(for: .milliseconds(20))
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

        try? await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(attemptCount == 0)

        coordinator.finishStoredReconnect(externalClaim)
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
        try? await ContinuousClock().sleep(for: .milliseconds(20))
        #expect(attemptCount == 1)
    }

    private func makeKeepAlive() -> OnboardingMacDiscoveryKeepAlive {
        OnboardingMacDiscoveryKeepAlive(
            retryDelay: .milliseconds(1),
            claimRetryDelay: .milliseconds(1)
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

#if os(iOS)
import Foundation
import os

private let onboardingDiscoveryLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "OnboardingDiscovery"
)

struct OnboardingDiscoveryAccountKey: Equatable {
    let userID: String?
    let teamID: String?
}

/// Keeps pre-connect onboarding discovery active while the root view owns it.
///
/// ``CMUXMobileRootView`` preserves this scheduler as `@State`. Its attempts
/// claim the shared ``MobileStartupConnectionCoordinator``, serializing them
/// with the root's startup one-shot and any injected-attach launch route.
@MainActor
final class OnboardingMacDiscoveryKeepAlive {
    private let clock: any Clock<Duration>
    private let retryDelay: Duration
    /// Ceiling for the grown retry delay: someone parked on a tour page for
    /// minutes should not poll the backup/registry every few seconds forever.
    private let maxRetryDelay: Duration
    private let claimRetryDelay: Duration

    private var coordinator: MobileStartupConnectionCoordinator?
    private var runAttempt: (@MainActor () async -> Bool)?
    /// Live pull-check consulted by the loop before every attempt and re-arm.
    /// SwiftUI `onChange` pushes are only wakeups; a dropped or coalesced push
    /// must never leave the loop searching after the connect page took over,
    /// the app connected, or onboarding finished.
    private var isStillEligible: (@MainActor () -> Bool)?
    private var loopTask: Task<Void, Never>?
    private var loopGeneration = 0
    private var runningAccountKey: OnboardingDiscoveryAccountKey?
    private var isEnabled = false

    private(set) var isRunning = false

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        retryDelay: Duration = .seconds(4),
        maxRetryDelay: Duration = .seconds(15),
        claimRetryDelay: Duration = .seconds(1)
    ) {
        self.clock = clock
        self.retryDelay = retryDelay
        self.maxRetryDelay = maxRetryDelay
        self.claimRetryDelay = claimRetryDelay
    }

    func update(
        isDiscoveryAuthorized: Bool,
        accountKey: OnboardingDiscoveryAccountKey,
        shouldKeepSearching: Bool,
        isStillEligible: @escaping @MainActor () -> Bool,
        coordinator: MobileStartupConnectionCoordinator,
        runAttempt: @escaping @MainActor () async -> Bool
    ) {
        self.coordinator = coordinator
        self.runAttempt = runAttempt
        self.isStillEligible = isStillEligible

        let accountChanged = runningAccountKey.map { $0 != accountKey } ?? false
        if !isDiscoveryAuthorized || accountChanged {
            hardCancel()
        }

        guard isDiscoveryAuthorized, shouldKeepSearching else {
            if isEnabled {
                onboardingDiscoveryLog.info("keep-alive disabled authorized=\(isDiscoveryAuthorized, privacy: .public) searching=\(shouldKeepSearching, privacy: .public)")
            }
            isEnabled = false
            return
        }

        if !isEnabled {
            onboardingDiscoveryLog.info("keep-alive enabled")
        }
        isEnabled = true
        guard loopTask == nil else { return }
        startLoop(accountKey: accountKey)
    }

    private func hardCancel() {
        if isEnabled || loopTask != nil {
            onboardingDiscoveryLog.info("keep-alive cancelled")
        }
        isEnabled = false
        loopGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        runningAccountKey = nil
        isRunning = false
    }

    private func startLoop(accountKey: OnboardingDiscoveryAccountKey) {
        loopGeneration &+= 1
        let generation = loopGeneration
        runningAccountKey = accountKey
        isRunning = true
        loopTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: Int) async {
        defer {
            if loopGeneration == generation {
                loopTask = nil
                runningAccountKey = nil
                isRunning = false
            }
        }

        var delay = retryDelay
        while !Task.isCancelled, isEnabled, isStillEligible?() == true {
            guard let coordinator, let runAttempt else { break }
            guard let claim = coordinator.claimStoredReconnect() else {
                try? await clock.sleep(for: claimRetryDelay)
                continue
            }

            onboardingDiscoveryLog.info("keep-alive attempt started generation=\(generation, privacy: .public)")
            let didConnect: Bool
            do {
                defer { coordinator.finishStoredReconnect(claim) }
                didConnect = await runAttempt()
            }
            onboardingDiscoveryLog.info("keep-alive attempt finished generation=\(generation, privacy: .public) didConnect=\(didConnect, privacy: .public)")

            guard !Task.isCancelled, !didConnect, isEnabled, isStillEligible?() == true else { break }
            try? await clock.sleep(for: delay)
            delay = min(delay * 3 / 2, maxRetryDelay)
        }
    }
}
#endif

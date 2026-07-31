import CmuxAuthRuntime
import Foundation
import Testing

@testable import CmuxMobileShellUI

private actor LifecyclePushRegistration: PushRegistering {
    private var value: PushRegistrationSnapshot
    private let setEnabledGate: LifecycleSetEnabledGate?
    private let syncGate: LifecycleSyncGate?

    init(
        enabled: Bool = true,
        snapshot: PushRegistrationSnapshot? = nil,
        setEnabledGate: LifecycleSetEnabledGate? = nil,
        syncGate: LifecycleSyncGate? = nil
    ) {
        value = snapshot
            ?? (enabled ? PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: false,
                backendState: .awaitingDeviceToken
            )
            : .disabled)
        self.setEnabledGate = setEnabledGate
        self.syncGate = syncGate
    }

    var isEnabled: Bool { value.isEnabled }
    var snapshot: PushRegistrationSnapshot { value }

    func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        await setEnabledGate?.pause()
        value = enabled
            ? PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: value.hasDeviceToken,
                backendState: value.hasDeviceToken
                    ? .registrationRequired
                    : .awaitingDeviceToken
            )
            : .disabled
    }

    func register(deviceToken: Data) {
        value = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: true,
            backendState: .registered
        )
    }

    func deviceTokenRegistrationFailed() {
        value = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: false,
            backendState: .deviceTokenRegistrationFailed
        )
    }

    func syncTokenIfPossible() async {
        await syncGate?.pause()
        guard value.isEnabled, value.hasDeviceToken else { return }
        value = PushRegistrationSnapshot(
            isEnabled: true,
            hasDeviceToken: true,
            backendState: .registered
        )
    }
    func unregisterFromServer() {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) {}
}

private actor LifecycleSetEnabledGate {
    private var didStart = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor LifecycleSyncGate {
    private(set) var starts = 0
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        starts += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard starts == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@Suite struct MobilePushCoordinatorLifecycleTests {
    @MainActor
    @Test func callbackFailureOffersRetryAndSuccessfulTokenRecoversReadiness() async {
        let registration = LifecyclePushRegistration()
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )
        await coordinator.refreshReadiness()

        await coordinator.handleDeviceTokenFailure()

        #expect(
            coordinator.registrationSnapshot.backendState
                == .deviceTokenRegistrationFailed
        )
        #expect(
            coordinator.readiness(macStatus: nil)
                == .blocked(.deviceTokenRegistrationFailed)
        )

        coordinator.retryDeviceTokenRegistration()
        #expect(registrationRequests == 1)

        await coordinator.handleDeviceToken(Data(repeating: 0xCD, count: 32))
        #expect(coordinator.registrationSnapshot.backendState == .registered)
    }

    @MainActor
    @Test func enableRegistersWithOSBeforeBackendSyncCompletes() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: false,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-enable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )

        let enabling = Task { await coordinator.enable() }
        await gate.waitUntilStarted()

        #expect(registrationRequests == 1)
        #expect(coordinator.isEnabled)
        #expect(coordinator.registrationSnapshot.isEnabled)

        await gate.release()
        #expect(await enabling.value)
    }

    @MainActor
    @Test func disableUnregistersWithOSBeforeBackendCleanupCompletes() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: true,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-disable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        var unregistrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            unregisterForRemoteNotifications: {
                unregistrationRequests += 1
            }
        )

        let disabling = Task { await coordinator.disable() }
        await gate.waitUntilStarted()

        #expect(unregistrationRequests == 1)
        #expect(!coordinator.isEnabled)
        #expect(coordinator.registrationSnapshot == .disabled)

        await gate.release()
        await disabling.value
    }

    @MainActor
    @Test func foregroundAndReachabilityRecoveryShareOneExhaustedRegistrationRetry() async {
        let gate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(
            snapshot: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .failed(.networkUnavailable)
            ),
            syncGate: gate
        )
        let coordinator = MobilePushCoordinator(
            registration: registration,
            authorizationStatus: { .authorized }
        )

        let firstRefresh = Task { @MainActor in
            await coordinator.refreshReadiness()
        }
        await gate.waitUntilStarted()
        let secondRefresh = Task { @MainActor in
            await coordinator.networkDidBecomeReachable()
        }
        await Task.yield()

        #expect(await gate.starts == 1)

        await gate.release()
        await firstRefresh.value
        await secondRefresh.value

        #expect(await gate.starts == 1)
        #expect(coordinator.registrationSnapshot.backendState == .registered)
    }
}

import CmuxAuthRuntime
import Foundation
import Testing
import UserNotifications

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
    func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) {}
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
        let suiteName = "push-coordinator-callback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
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
    @Test func authorizedEnableRecoversWithoutRequestingAuthorizationAgain() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-authorized-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var authorizationRequests = 0
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            requestAuthorization: {
                authorizationRequests += 1
                return false
            },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )

        #expect(await coordinator.enable())
        #expect(authorizationRequests == 0)
        #expect(registrationRequests == 1)
        #expect(coordinator.isEnabled)
        #expect(await registration.snapshot.isEnabled)
    }

    @MainActor
    @Test func deniedEnablePersistsIntentAndDoesNotReaskTheSystem() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-denied-intent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var authorizationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .denied },
            requestAuthorization: {
                authorizationRequests += 1
                return false
            }
        )

        #expect(!(await coordinator.enable()))
        #expect(authorizationRequests == 0)
        #expect(coordinator.isEnabled)
        #expect(
            defaults.object(forKey: "cmux.notifications.pushEnabled") as? Bool
                == true
        )
        #expect(
            coordinator.readiness(macStatus: nil)
                == .blocked(.systemPermissionDenied)
        )
    }

    @MainActor
    @Test func foregroundRefreshRegistersAfterPermissionIsEnabledInSettings() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-settings-return-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        var status = UNAuthorizationStatus.denied
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { status },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )

        await coordinator.refreshReadiness()
        #expect(registrationRequests == 0)
        #expect(!(await registration.snapshot.isEnabled))

        status = .authorized
        await coordinator.refreshReadiness()

        #expect(registrationRequests == 1)
        #expect(await registration.snapshot.isEnabled)
        #expect(coordinator.authorization == .authorized)
    }

    @MainActor
    @Test func foregroundRefreshPreservesExplicitAppOptOut() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-explicit-optout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "cmux.notifications.pushEnabled")
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .provisional },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )

        await coordinator.refreshReadiness()

        #expect(registrationRequests == 0)
        #expect(!(await registration.snapshot.isEnabled))
        #expect(!coordinator.isEnabled)
    }

    @MainActor
    @Test func optInPersistsAcrossCoordinatorRecreation() async {
        let suiteName = "push-coordinator-persistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registration = LifecyclePushRegistration(enabled: false)
        let enabled = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            requestAuthorization: { true }
        )

        #expect(await enabled.enable())
        #expect(
            defaults.object(
                forKey: "cmux.notifications.pushEnabled"
            ) as? Bool == true
        )
        #expect(MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized }
        ).isEnabled)

        await enabled.disable()
        #expect(
            defaults.object(
                forKey: "cmux.notifications.pushEnabled"
            ) as? Bool == false
        )
        #expect(!MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized }
        ).isEnabled)
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
        let suiteName = "push-coordinator-shared-retry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
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

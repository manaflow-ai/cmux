import CmuxAuthRuntime
import Foundation
import Testing
import UserNotifications

@testable import CmuxMobileShellUI

private actor LifecyclePushRegistration: PushRegistering {
    private var value: PushRegistrationSnapshot
    private var snapshotRead = false
    private var snapshotReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotContinuation:
        AsyncStream<PushRegistrationSnapshot>.Continuation?
    private var queuedSnapshots: [PushRegistrationSnapshot] = []
    private var latestIntentGeneration: UInt64 = 0
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
    var snapshot: PushRegistrationSnapshot {
        snapshotRead = true
        let waiters = snapshotReadWaiters
        snapshotReadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return value
    }

    func waitUntilSnapshotRead() async {
        guard !snapshotRead else { return }
        await withCheckedContinuation { continuation in
            snapshotReadWaiters.append(continuation)
        }
    }

    func snapshots() -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            Task { await self.installSnapshotContinuation(continuation) }
        }
    }

    private func installSnapshotContinuation(
        _ continuation: AsyncStream<PushRegistrationSnapshot>.Continuation
    ) {
        snapshotContinuation = continuation
        continuation.yield(value)
        for snapshot in queuedSnapshots {
            continuation.yield(snapshot)
        }
        queuedSnapshots.removeAll()
    }

    func emit(_ snapshot: PushRegistrationSnapshot) {
        value = snapshot
        if let snapshotContinuation {
            snapshotContinuation.yield(snapshot)
        } else {
            queuedSnapshots.append(snapshot)
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

    func disableAndUnregister() async {
        await setEnabledGate?.pause()
        value = .disabled
    }

    func applyEnabledIntent(
        _ enabled: Bool,
        generation: UInt64,
        intentEpoch: PushRegistrationIntentEpoch
    ) async {
        guard generation >= latestIntentGeneration else { return }
        latestIntentGeneration = generation
        if enabled {
            await setEnabledGate?.pause()
            guard generation == latestIntentGeneration else { return }
            value = PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: value.hasDeviceToken,
                backendState: value.hasDeviceToken
                    ? .registrationRequired
                    : .awaitingDeviceToken
            )
        } else {
            await setEnabledGate?.pause()
            guard generation == latestIntentGeneration else { return }
            value = .disabled
        }
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

private struct LifecycleTokenProvider: TokenProviding {
    private let session = AuthenticatedSessionSnapshot(
        generation: 1,
        accountID: "push-lifecycle-user",
        accessToken: "push-lifecycle-access",
        refreshToken: "push-lifecycle-refresh"
    )

    func authenticatedSessionSnapshot() async throws
        -> AuthenticatedSessionSnapshot {
        session
    }

    func isAuthenticatedSessionCurrent(
        _ snapshot: AuthenticatedSessionSnapshot
    ) async -> Bool {
        snapshot == session
    }

    func accessToken() async throws -> String { session.accessToken }
    func storedAccessToken() async -> String? { session.accessToken }
    func refreshToken() async -> String? { session.refreshToken }
    func forceRefreshAccessToken() async throws -> String {
        session.accessToken
    }
}

private final class LifecycleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMethods: [String] = []

    var methods: [String] { lock.withLock { storedMethods } }

    func record(_ request: URLRequest) {
        lock.withLock { storedMethods.append(request.httpMethod ?? "?") }
    }

    func reset() {
        lock.withLock { storedMethods.removeAll() }
    }
}

private final class LifecyclePushURLProtocol: URLProtocol,
    @unchecked Sendable {
    static let recorder = LifecycleRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
    @Test func optOutInvalidatesAnEnableSuspendedInNotificationSettings() async {
        let settingsGate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-stale-enable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.authorized)
            },
            registerForRemoteNotifications: {}
        )

        let enabling = Task { await coordinator.enable() }
        await settingsGate.waitUntilStarted()

        coordinator.setEnabledIntent(false)
        #expect(!coordinator.isEnabled)
        #expect(!defaults.bool(forKey: "cmux.notifications.pushEnabled"))

        await settingsGate.release()
        #expect(!(await enabling.value))
        for _ in 0..<100 {
            if await registration.snapshot == .disabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot == .disabled)
        #expect(!coordinator.isEnabled)
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
    @Test func repeatedForegroundAndWorkspaceActivationRequestsAPNsOnce() async {
        let registration = LifecyclePushRegistration(enabled: true)
        let suiteName = "push-coordinator-apns-dedupe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            registerForRemoteNotifications: { registrationRequests += 1 }
        )

        await coordinator.refreshReadiness()
        await coordinator.workspaceListDidBecomeVisible()
        await coordinator.refreshReadiness()

        #expect(registrationRequests == 1)
    }

    @MainActor
    @Test func sharedDefaultsDisableInvokesProductionBackendUnregister() async {
        LifecyclePushURLProtocol.recorder.reset()
        let suiteName = "push-coordinator-shared-disable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecyclePushURLProtocol.self]
        let registration = PushRegistrationService(
            tokenProvider: LifecycleTokenProvider(),
            apiBaseURL: "https://push-lifecycle.test",
            bundleID: "dev.cmux.ios.push-lifecycle",
            apnsEnvironment: "sandbox",
            suiteName: suiteName,
            session: URLSession(configuration: configuration),
            retryDelays: []
        )
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {}
        )

        #expect(await coordinator.enable())
        await coordinator.handleDeviceToken(Data([0xAB, 0xCD]))
        await coordinator.disable()

        #expect(LifecyclePushURLProtocol.recorder.methods == ["POST", "DELETE"])
        #expect(!defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await registration.snapshot == .disabled)
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
    @Test func settingsOptOutIsVisibleBeforeCoordinatorBackendCleanupCompletes() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: true,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-settings-optout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            unregisterForRemoteNotifications: {}
        )

        coordinator.setEnabledIntent(false)
        await gate.waitUntilStarted()
        await coordinator.workspaceListDidBecomeVisible()

        #expect(!coordinator.isEnabled)
        #expect(coordinator.registrationSnapshot == .disabled)

        await gate.release()
        for _ in 0..<100 {
            if await registration.snapshot == .disabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot == .disabled)
        #expect(!defaults.bool(forKey: "cmux.notifications.pushEnabled"))
    }

    @MainActor
    @Test func settingsOptOutPreemptsAnInFlightEnable() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: false,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-settings-preempt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            unregisterForRemoteNotifications: {}
        )

        coordinator.setEnabledIntent(true)
        await gate.waitUntilStarted()

        coordinator.setEnabledIntent(false)
        #expect(!coordinator.isEnabled)

        await gate.release()
        for _ in 0..<100 {
            if await registration.snapshot == .disabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot == .disabled)
        #expect(!defaults.bool(forKey: "cmux.notifications.pushEnabled"))
    }

    @MainActor
    @Test func staleDisabledSnapshotCannotReplaceReenabledIntent() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: true,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-stale-snapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized }
        )
        coordinator.configure(delegate: LifecycleNotificationDelegate())
        for _ in 0..<100 {
            if coordinator.registrationSnapshot.isEnabled { break }
            await Task.yield()
        }

        coordinator.setEnabledIntent(false)
        await gate.waitUntilStarted()
        coordinator.setEnabledIntent(true)
        await registration.emit(.disabled)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(coordinator.isEnabled)
        #expect(coordinator.registrationSnapshot != .disabled)

        await gate.release()
        for _ in 0..<100 {
            if await registration.snapshot.isEnabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot.isEnabled)
    }

    @MainActor
    @Test func reenableIntentIsSubmittedWhileDisableStillReportsEnabled() async {
        let gate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(
            enabled: true,
            setEnabledGate: gate
        )
        let suiteName = "push-coordinator-reenable-generation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized }
        )

        coordinator.setEnabledIntent(false)
        await gate.waitUntilStarted()

        coordinator.setEnabledIntent(true)
        await registration.waitUntilSnapshotRead()

        await gate.release()
        for _ in 0..<100 {
            if await registration.snapshot.isEnabled { break }
            await Task.yield()
        }

        #expect(await registration.snapshot.isEnabled)
        #expect(coordinator.isEnabled)
    }

    @MainActor
    @Test func cancelledEnableStillCompletesCommittedIntent() async {
        let authorizationGate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-cancelled-enable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .notDetermined },
            requestAuthorization: {
                await authorizationGate.pause()
                return true
            }
        )

        let enabling = Task { @MainActor in
            await coordinator.enable()
        }
        await authorizationGate.waitUntilStarted()
        enabling.cancel()
        await authorizationGate.release()
        _ = await enabling.value

        for _ in 0..<100 {
            if await registration.snapshot.isEnabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot.isEnabled)
        #expect(coordinator.isEnabled)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
    }

    @MainActor
    @Test func stalledSettingsMutationTimesOutAndReleasesLifecycleSlot() async {
        let settingsGate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-settings-timeout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.authorized)
            },
            registerForRemoteNotifications: { registrationRequests += 1 },
            settingsMutationSleep: { _ in
                await settingsGate.waitUntilStarted()
            }
        )

        coordinator.setEnabledIntent(true)
        await settingsGate.waitUntilStarted()
        for _ in 0..<100 {
            if coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable) {
                break
            }
            await Task.yield()
        }

        #expect(coordinator.isEnabled)
        #expect(
            coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable)
        )

        coordinator.setEnabledIntent(true)
        for _ in 0..<100 {
            if await settingsGate.starts == 2 { break }
            await Task.yield()
        }
        #expect(await settingsGate.starts == 2)

        await settingsGate.release()
        for _ in 0..<100 {
            if registrationRequests == 1 { break }
            await Task.yield()
        }
        #expect(registrationRequests == 1)
        await coordinator.workspaceListDidBecomeVisible()
        #expect(await registration.snapshot.isEnabled)
    }

    @MainActor
    @Test func publicEnableUsesSettingsMutationTimeout() async {
        let settingsGate = LifecycleSyncGate()
        let timeoutGate = LifecycleSyncGate()
        let timeoutSleeper = LifecycleSettingsMutationSleeper(
            firstGate: timeoutGate
        )
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-public-enable-timeout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.authorized)
            },
            settingsMutationSleep: { duration in
                try await timeoutSleeper.sleep(for: duration)
            }
        )

        let enabling = Task { await coordinator.enable() }
        await settingsGate.waitUntilStarted()
        for _ in 0..<100 where await timeoutGate.starts == 0 {
            await Task.yield()
        }
        #expect(await timeoutGate.starts == 1)

        await timeoutGate.release()
        for _ in 0..<100 {
            if coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable) {
                break
            }
            await Task.yield()
        }
        #expect(
            coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable)
        )

        await settingsGate.release()
        #expect(!(await enabling.value))
    }

    @MainActor
    @Test func timedOutEnableAllowsOneBoundedRecoveryAndCannotBlockOptOut() async {
        let settingsGate = LifecycleSyncGate()
        let timeoutGate = LifecycleSyncGate()
        let timeoutSleeper = LifecycleSettingsMutationSleeper(
            firstGate: timeoutGate
        )
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-timeout-dedup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.authorized)
            },
            settingsMutationSleep: { duration in
                try await timeoutSleeper.sleep(for: duration)
            }
        )

        coordinator.setEnabledIntent(true)
        await settingsGate.waitUntilStarted()
        await timeoutGate.waitUntilStarted()
        await timeoutGate.release()
        for _ in 0..<100 {
            if coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable) {
                break
            }
            await Task.yield()
        }

        coordinator.setEnabledIntent(true)
        for _ in 0..<100 {
            if await settingsGate.starts == 2,
               await registration.snapshot.isEnabled {
                break
            }
            await Task.yield()
        }
        #expect(await settingsGate.starts == 2)
        #expect(await registration.snapshot.isEnabled)

        coordinator.setEnabledIntent(true)
        for _ in 0..<100 { await Task.yield() }
        #expect(await settingsGate.starts == 2)

        coordinator.setEnabledIntent(false)
        for _ in 0..<100 {
            if !coordinator.isEnabled,
               await registration.snapshot == .disabled {
                break
            }
            await Task.yield()
        }
        #expect(!coordinator.isEnabled)
        #expect(await registration.snapshot == .disabled)

        await settingsGate.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(!coordinator.isEnabled)
        #expect(await registration.snapshot == .disabled)
    }

    @MainActor
    @Test func lateAuthorizationAfterTimeoutStartsFreshReconciliation() async {
        let authorizationGate = LifecycleSyncGate()
        let timeoutGate = LifecycleSyncGate()
        let timeoutSleeper = LifecycleSettingsMutationSleeper(
            firstGate: timeoutGate
        )
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-late-authorization-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var authorization = MobilePushAuthorization.notDetermined
        var registrationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                .authorizationOnly(authorization)
            },
            requestAuthorization: {
                await authorizationGate.pause()
                authorization = .authorized
                return true
            },
            registerForRemoteNotifications: { registrationRequests += 1 },
            settingsMutationSleep: { duration in
                try await timeoutSleeper.sleep(for: duration)
            }
        )

        coordinator.setEnabledIntent(true)
        await authorizationGate.waitUntilStarted()
        await timeoutGate.waitUntilStarted()
        await timeoutGate.release()
        for _ in 0..<100 {
            if coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable) {
                break
            }
            await Task.yield()
        }
        #expect(
            coordinator.registrationSnapshot.backendState
                == .failed(.networkUnavailable)
        )

        await authorizationGate.release()
        for _ in 0..<100 {
            if registrationRequests == 1 { break }
            await Task.yield()
        }
        #expect(registrationRequests == 1)
        for _ in 0..<100 {
            if await registration.snapshot.isEnabled { break }
            await Task.yield()
        }
        #expect(await registration.snapshot.isEnabled)
    }

    @MainActor
    @Test func supersedingSettingsIntentCancelsMutationWorkers() async {
        let authorizationGate = LifecycleSyncGate()
        let timeoutGate = LifecycleSyncGate()
        let timeoutSleeper = LifecycleSettingsMutationSleeper(
            firstGate: timeoutGate
        )
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-cancel-workers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cancellationRecorder = LifecycleCancellationRecorder()
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .notDetermined },
            requestAuthorization: {
                await authorizationGate.pause()
                await cancellationRecorder.recordAuthorizationCancellation(
                    Task.isCancelled
                )
                return true
            },
            settingsMutationSleep: { duration in
                try await timeoutSleeper.sleep(for: duration)
            }
        )

        coordinator.setEnabledIntent(true)
        await authorizationGate.waitUntilStarted()
        await timeoutGate.waitUntilStarted()
        coordinator.setEnabledIntent(false)
        await authorizationGate.release()
        await timeoutGate.release()
        for _ in 0..<100 {
            if !coordinator.isEnabled, await registration.snapshot == .disabled {
                break
            }
            await Task.yield()
        }

        #expect(await cancellationRecorder.didCancelAuthorization)
        #expect(!coordinator.isEnabled)
        #expect(await registration.snapshot == .disabled)
    }

    @MainActor
    @Test func deniedReenableSupersedesInFlightDisable() async {
        let disableGate = LifecycleSetEnabledGate()
        let settingsGate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(
            enabled: true,
            setEnabledGate: disableGate
        )
        let suiteName = "push-coordinator-denied-reenable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.denied)
            }
        )

        coordinator.setEnabledIntent(false)
        await disableGate.waitUntilStarted()

        coordinator.setEnabledIntent(true)
        await settingsGate.waitUntilStarted()
        await settingsGate.release()
        for _ in 0..<20 {
            await Task.yield()
        }

        await disableGate.release()
        for _ in 0..<100 {
            if await registration.snapshot.isEnabled { break }
            await Task.yield()
        }

        #expect(await registration.snapshot.isEnabled)
        #expect(coordinator.isEnabled)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
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

    @MainActor
    @Test func timedOutRegistrationRecoveryStartsOneBoundedFreshRetry() async {
        let syncGate = LifecycleSyncGate()
        let timeoutGate = LifecycleSyncGate()
        let registration = LifecyclePushRegistration(
            snapshot: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .failed(.networkUnavailable)
            ),
            syncGate: syncGate
        )
        let suiteName = "push-coordinator-recovery-timeout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized },
            settingsMutationSleep: { _ in await timeoutGate.pause() }
        )

        let first = Task { @MainActor in await coordinator.enable() }
        await syncGate.waitUntilStarted()
        await timeoutGate.waitUntilStarted()
        await timeoutGate.release()
        _ = await first.value

        let second = Task { @MainActor in
            await coordinator.networkDidBecomeReachable()
        }
        let freshRetryStarted = await syncGate.waitUntilStartCount(2)
        let third = Task { @MainActor in
            await coordinator.networkDidBecomeReachable()
        }
        for _ in 0..<100 { await Task.yield() }

        #expect(freshRetryStarted)
        #expect(await syncGate.starts == 2)

        await syncGate.release()
        await second.value
        await third.value
    }
}

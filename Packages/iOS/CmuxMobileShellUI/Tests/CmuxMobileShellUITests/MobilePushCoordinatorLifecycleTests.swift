import CmuxAuthRuntime
import Foundation
import Testing
import UserNotifications

@testable import CmuxMobileShellUI

private actor LifecyclePushRegistration: PushRegistering {
    private var value: PushRegistrationSnapshot
    private var intentGeneration: UInt64 = 0
    private(set) var enabledReconciliationGenerations: [UInt64] = []
    private(set) var syncCount = 0
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
        apply(enabled)
    }

    func applyEnabledIntent(_ enabled: Bool, generation: UInt64) async {
        guard generation >= intentGeneration else { return }
        await setEnabledGate?.pause()
        guard generation >= intentGeneration else { return }
        intentGeneration = generation
        apply(enabled)
    }

    func reconcileEnabledIntent(generation: UInt64) {
        guard generation == intentGeneration, value.isEnabled else { return }
        enabledReconciliationGenerations.append(generation)
    }

    private func apply(_ enabled: Bool) {
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
        syncCount += 1
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

    /// The workspace list is an automatic surface: it must never spend the
    /// app's one OS permission prompt. Only an explicit opt-in (the onboarding
    /// push page or the Settings toggle) may ask an undetermined system.
    @MainActor
    @Test func workspaceListNeverPromptsAnUndeterminedSystem() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-workspace-noprompt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var authorizationRequests = 0
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .notDetermined },
            requestAuthorization: {
                authorizationRequests += 1
                return true
            }
        )

        await coordinator.workspaceListDidBecomeVisible()

        #expect(authorizationRequests == 0)
        #expect(!coordinator.isEnabled)
        #expect(defaults.object(forKey: "cmux.notifications.pushEnabled") == nil)

        #expect(await coordinator.enable(trigger: "onboarding"))
        #expect(authorizationRequests == 1)
        #expect(coordinator.isEnabled)
    }

    @MainActor
    @Test func deniedSettingsIntentReconcilesAfterPermissionIsGranted() async {
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-denied-backend-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var status = UNAuthorizationStatus.denied
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { status },
            requestAuthorization: { false }
        )
        await coordinator.refreshReadiness()

        #expect(!(await coordinator.setEnabledIntent(true).value))
        #expect(await registration.enabledReconciliationGenerations.isEmpty)
        #expect(coordinator.isEnabled)

        status = .authorized
        await coordinator.refreshReadiness()

        #expect(
            await registration.enabledReconciliationGenerations == [1]
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
    @Test func repeatedForegroundDoesNotReuploadRegisteredToken() async {
        let registration = LifecyclePushRegistration(
            snapshot: PushRegistrationSnapshot(
                isEnabled: true,
                hasDeviceToken: true,
                backendState: .registered
            )
        )
        let suiteName = "push-coordinator-registered-dedupe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmux.notifications.pushEnabled")
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            authorizationStatus: { .authorized }
        )

        await coordinator.refreshReadiness()
        await coordinator.refreshReadiness()

        #expect(await registration.syncCount == 0)
        #expect(coordinator.registrationSnapshot.backendState == .registered)
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
    @Test func latestSettingsIntentSupersedesStalledEnable() async {
        let settingsGate = LifecycleSetEnabledGate()
        let registration = LifecyclePushRegistration(enabled: false)
        let suiteName = "push-coordinator-latest-intent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = MobilePushCoordinator(
            registration: registration,
            defaults: defaults,
            notificationSettings: {
                await settingsGate.pause()
                return .authorizationOnly(.authorized)
            },
            requestAuthorization: { true }
        )

        let enabling = coordinator.setEnabledIntent(true)
        await settingsGate.waitUntilStarted()

        let disabling = coordinator.setEnabledIntent(false)
        #expect(!coordinator.isEnabled)
        #expect(
            defaults.object(forKey: "cmux.notifications.pushEnabled") as? Bool
                == false
        )

        await disabling.value
        let reenabling = coordinator.setEnabledIntent(true)
        #expect(coordinator.isEnabled)
        await settingsGate.release()
        await enabling.value
        #expect(await reenabling.value)

        #expect(coordinator.isEnabled)
        #expect(await registration.snapshot.isEnabled)
        #expect(await registration.enabledReconciliationGenerations == [3])
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

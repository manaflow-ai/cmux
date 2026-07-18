import CmuxTerminalBackend
import CmuxTerminalBackendService
import Foundation
import Testing

@Suite("Persistent backend launch service")
struct BackendServiceBootstrapCoordinatorTests {
    @Test("enabled service is not re-registered")
    func enabledServiceIsPreserved() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .enabled)
        let readiness = FakeReadinessChecker()
        let coordinator = makeCoordinator(
            fixture: fixture,
            registration: registration,
            readiness: readiness
        )

        #expect(try await coordinator.ensureRegistered() == .ready(Self.readinessProof))
        #expect(await registration.registerCount == 0)
        #expect(await readiness.checkCount == 1)
        #expect(await coordinator.currentState() == .ready(Self.readinessProof))
    }

    @Test("missing service is registered exactly once")
    func registerOnce() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(
            status: .notRegistered,
            statusAfterRegister: .enabled
        )
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        #expect(try await coordinator.ensureRegistered() == .ready(Self.readinessProof))
        #expect(await registration.registerCount == 1)
        #expect(await coordinator.currentState() == .ready(Self.readinessProof))
    }

    @Test("concurrent ensure calls share one registration operation")
    func concurrentEnsureIsCoalesced() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(
            status: .notRegistered,
            statusAfterRegister: .enabled,
            blockRegister: true
        )
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        let first = Task { try await coordinator.ensureRegistered() }
        await registration.waitUntilRegisterStarted()
        let second = Task { try await coordinator.ensureRegistered() }
        await Task.yield()
        #expect(await registration.registerCount == 1)
        await registration.releaseRegister()

        #expect(try await first.value == .ready(Self.readinessProof))
        #expect(try await second.value == .ready(Self.readinessProof))
        #expect(await registration.registerCount == 1)
    }

    @Test("user approval state is surfaced without retry loop")
    func approvalRequired() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .requiresApproval)
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        #expect(try await coordinator.ensureRegistered() == .requiresApproval)
        #expect(await registration.registerCount == 0)
        #expect(await coordinator.currentState() == .requiresApproval)
    }

    @Test("bundle validation runs before registration")
    func missingExecutable() async throws {
        let fixture = try Fixture(createExecutable: false)
        let registration = FakeRegistration(status: .notRegistered)
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        let result = try await coordinator.ensureRegistered()
        guard case .missingBundleItem(.executable(let url)) = result else {
            Issue.record("expected missing executable, got \(result)")
            return
        }
        #expect(url.lastPathComponent == "cmux-terminal-backend")
        #expect(await registration.registerCount == 0)
    }

    @Test("disabled feature gate performs no filesystem or registration work")
    func disabledGateIsInert() async throws {
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-backend-disabled-\(UUID())", isDirectory: true)
        let descriptor = BackendServiceDescriptor.production
        let inspection = BackendServiceBundleInspection(
            bundleURL: missingBundle,
            descriptor: descriptor
        )
        let registration = FakeRegistration(status: .notRegistered)
        let coordinator = BackendServiceBootstrapCoordinator(
            activationPolicy: .init(buildSettingValue: "NO"),
            inspection: inspection,
            registration: registration,
            readinessChecker: FakeReadinessChecker()
        )

        #expect(try await coordinator.ensureRegistered() == .disabled)
        #expect(await registration.registerCount == 0)
        #expect(await coordinator.currentState() == .disabled)
    }

    @Test("successful registration is not retried while status propagation is pending")
    func pendingStatusAfterRegistrationIsAccepted() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(
            status: .notRegistered,
            statusAfterRegister: .notRegistered
        )
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        #expect(try await coordinator.ensureRegistered() == .ready(Self.readinessProof))
        #expect(await registration.registerCount == 1)
    }

    @Test("explicit unregister waits for the adapter exactly once")
    func unregisterEnabledService() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .enabled)
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        #expect(try await coordinator.unregister() == .unregistered)
        #expect(await registration.unregisterCount == 1)
        #expect(await coordinator.currentState() == .unregistered)
        #expect(try await coordinator.unregister() == .alreadyUnregistered)
        #expect(await registration.unregisterCount == 1)
    }

    @Test("late readiness cannot overwrite explicit unregistration")
    func unregisterInvalidatesReadiness() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .enabled)
        let readiness = ControllableReadinessChecker(readiness: Self.readinessProof)
        let coordinator = BackendServiceBootstrapCoordinator(
            activationPolicy: .init(buildSettingValue: "YES"),
            inspection: fixture.inspection,
            registration: registration,
            readinessChecker: readiness
        )

        let ensure = Task { try await coordinator.ensureRegistered() }
        await readiness.waitUntilStarted()
        #expect(try await coordinator.unregister() == .unregistered)
        await readiness.succeed()

        await #expect(throws: CancellationError.self) {
            try await ensure.value
        }
        #expect(await coordinator.currentState() == .unregistered)
    }

    @Test("state updates are seeded and retain the latest lifecycle state")
    func publishesLatestState() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .enabled)
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)
        let stream = await coordinator.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .checking)
        _ = try await coordinator.ensureRegistered()
        #expect(await iterator.next() == .ready(Self.readinessProof))
    }

    @Test("login items action is forwarded to the service adapter")
    func opensLoginItemsSettings() async throws {
        let fixture = try Fixture()
        let registration = FakeRegistration(status: .requiresApproval)
        let coordinator = makeCoordinator(fixture: fixture, registration: registration)

        await coordinator.openSystemSettingsLoginItems()

        #expect(await registration.openSettingsCount == 1)
    }

    private func makeCoordinator(
        fixture: Fixture,
        registration: FakeRegistration,
        readiness: FakeReadinessChecker = FakeReadinessChecker()
    ) -> BackendServiceBootstrapCoordinator {
        BackendServiceBootstrapCoordinator(
            activationPolicy: .init(buildSettingValue: "YES"),
            inspection: fixture.inspection,
            registration: registration,
            readinessChecker: readiness
        )
    }

    fileprivate static let readinessProof = BackendServiceReadiness(
        authority: BackendAuthority(
            daemonInstanceID: DaemonInstanceID(
                rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            ),
            sessionID: SessionID(
                rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
            )
        ),
        session: "cmux",
        processID: 42,
        userID: 501,
        peerIdentity: BackendPeerIdentity(
            processID: 42,
            userID: 501,
            auditToken: BackendAuditToken(
                word0: 1, word1: 2, word2: 3, word3: 4,
                word4: 5, word5: 6, word6: 7, word7: 8
            )
        ),
        peerTrust: BackendPeerTrustEvidence(
            signingIdentifier: SystemBackendPeerTrustVerifier.signingIdentifier,
            teamIdentifier: nil,
            executableURL: URL(fileURLWithPath: "/Applications/cmux.app/backend"),
            processIDVersion: 1
        ),
        topologyRevision: 7,
        compatibility: .readWrite(BackendReadWriteCompatibility(
            clientProtocolRange: 8 ... 9,
            serverProtocolRange: 8 ... 9,
            negotiatedProtocol: 9,
            requiredCapabilities: BackendHandshakePolicy.terminalAuthorityV1.requiredCapabilities
        ))
    )
}

private actor FakeReadinessChecker: BackendServiceReadinessChecking {
    private(set) var checkCount = 0

    func checkReadiness() -> BackendServiceReadiness {
        checkCount += 1
        return BackendServiceBootstrapCoordinatorTests.readinessProof
    }
}

private actor FakeRegistration: BackendServiceRegistration {
    private var storedStatus: BackendServiceStatus
    private let statusAfterRegister: BackendServiceStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0
    private let blockRegister: Bool
    private var registerStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var registerReleaseContinuation: CheckedContinuation<Void, Never>?

    init(
        status: BackendServiceStatus,
        statusAfterRegister: BackendServiceStatus? = nil,
        blockRegister: Bool = false
    ) {
        storedStatus = status
        self.statusAfterRegister = statusAfterRegister ?? status
        self.blockRegister = blockRegister
    }

    func status() -> BackendServiceStatus {
        storedStatus
    }

    func register() async {
        registerCount += 1
        for waiter in registerStartedWaiters { waiter.resume() }
        registerStartedWaiters.removeAll()
        if blockRegister {
            await withCheckedContinuation { continuation in
                registerReleaseContinuation = continuation
            }
        }
        storedStatus = statusAfterRegister
    }

    func waitUntilRegisterStarted() async {
        if registerCount > 0 { return }
        await withCheckedContinuation { continuation in
            registerStartedWaiters.append(continuation)
        }
    }

    func releaseRegister() {
        registerReleaseContinuation?.resume()
        registerReleaseContinuation = nil
    }

    func unregister() {
        unregisterCount += 1
        storedStatus = .notRegistered
    }

    func openSystemSettingsLoginItems() {
        openSettingsCount += 1
    }
}

private struct Fixture {
    let root: URL
    let inspection: BackendServiceBundleInspection

    init(createExecutable: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-backend-service-\(UUID())", isDirectory: true)
        let descriptor = BackendServiceDescriptor.production
        let propertyList = root
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(descriptor.propertyListName)
        try FileManager.default.createDirectory(
            at: propertyList.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("plist".utf8).write(to: propertyList)

        if createExecutable {
            let executable = root.appendingPathComponent(descriptor.executableRelativePath)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("binary".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }
        inspection = BackendServiceBundleInspection(
            bundleURL: root,
            descriptor: descriptor
        )
    }
}

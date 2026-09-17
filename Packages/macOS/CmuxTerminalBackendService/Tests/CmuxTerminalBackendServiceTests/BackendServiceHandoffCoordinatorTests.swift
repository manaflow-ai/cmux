@testable import CmuxTerminalBackendService
import CmuxTerminalBackend
import Darwin
import Foundation
import Testing

@Suite("Authenticated idle backend handoff")
struct BackendServiceHandoffCoordinatorTests {
    @Test("not-idle response defers without touching launchd")
    func deferredNotIdle() async throws {
        let harness = HandoffHarness(preparation: .deferredNotIdle(.fixture(canonicalSurfaces: 1)))
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        #expect(result == .deferredNotIdle(.fixture(canonicalSurfaces: 1)))
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
    }

    @Test("wrong source build in a daemon permit is cancelled before the service lock")
    func invalidPermitNeverTouchesLaunchd() async throws {
        let invalid = BackendServiceHandoffPermit.fixture(
            source: String(repeating: "4", count: 64),
            target: String(repeating: "2", count: 64)
        )
        let harness = HandoffHarness(preparation: .prepared(invalid))
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack(let failure, _) = result else {
            Issue.record("expected invalid permit rejection")
            return
        }
        #expect(failure.stage == .validatePermit)
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .cancelPermit,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
    }

    @Test("activation holds connection and lock through exact replacement and readiness")
    func activationOrder() async throws {
        let harness = HandoffHarness()
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .activated(let readiness) = result else {
            Issue.record("expected activation")
            return
        }
        #expect(readiness == harness.newReadiness)
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .acquireLock,
            .loadActiveDescriptor,
            .revalidatePermit,
            .bootoutOld,
            .writeNewDescriptor,
            .bootstrapNew,
            .checkNewReadiness,
            .releaseLock,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor?.pair == harness.newPair)
    }

    @Test("TOCTOU change under the app lock cancels drain and preserves the winner")
    func exactRevalidationRejectsRacingPair() async throws {
        let harness = HandoffHarness()
        await harness.replaceActiveWhenLockAcquired(with: harness.racingDescriptor)
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack(let failure, _) = result else {
            Issue.record("expected no-op rollback")
            return
        }
        #expect(failure.stage == .revalidateOldDescriptor)
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .acquireLock,
            .loadActiveDescriptor,
            .cancelPermit,
            .releaseLock,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor == harness.racingDescriptor)
    }

    @Test("new readiness failure removes only exact new and restores exact old bytes")
    func readinessFailureRollsBackExactly() async throws {
        let harness = HandoffHarness(failing: .checkNewReadiness)
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack(let failure, let readiness) = result else {
            Issue.record("expected successful rollback")
            return
        }
        #expect(failure.stage == .proveNewReadiness)
        #expect(readiness == harness.oldReadiness)
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .acquireLock,
            .loadActiveDescriptor,
            .revalidatePermit,
            .bootoutOld,
            .writeNewDescriptor,
            .bootstrapNew,
            .checkNewReadiness,
            .loadActiveDescriptor,
            .bootoutNew,
            .restoreOldDescriptor,
            .bootstrapOld,
            .checkOldReadiness,
            .releaseLock,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        #expect(await harness.restoredPropertyList == harness.oldDescriptor.propertyListData)
    }

    @Test("racing descriptor during rollback is preserved and reported")
    func rollbackNeverBootsOutRacingPair() async throws {
        let harness = HandoffHarness(failing: .checkNewReadiness)
        await harness.replaceActiveBeforeRollback(with: harness.racingDescriptor)
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rollbackFailed(let activationFailure, let rollbackFailure) = result else {
            Issue.record("expected rollback failure")
            return
        }
        #expect(activationFailure.stage == .proveNewReadiness)
        #expect(rollbackFailure.stage == .revalidateNewDescriptor)
        #expect(await harness.operations == [
            .stageTarget,
            .loadActiveDescriptor,
            .connectCoordinator,
            .preparePermit,
            .acquireLock,
            .loadActiveDescriptor,
            .revalidatePermit,
            .bootoutOld,
            .writeNewDescriptor,
            .bootstrapNew,
            .checkNewReadiness,
            .loadActiveDescriptor,
            .releaseLock,
            .closeCoordinator,
        ])
        #expect(await harness.activeDescriptor == harness.racingDescriptor)
    }

    @Test("each pre-bootout failure cancels drain and leaves old daemon active", arguments: [
        HandoffOperation.connectCoordinator,
        .preparePermit,
        .acquireLock,
        .loadActiveDescriptor,
        .revalidatePermit,
        .bootoutOld,
    ])
    fileprivate func preBootoutFailure(step: HandoffOperation) async throws {
        let harness = HandoffHarness(failing: step)
        let coordinator = harness.coordinator()

        _ = try await coordinator.activateStagedPairIfIdle()

        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        if step == .acquireLock || step == .loadActiveDescriptor
            || step == .revalidatePermit || step == .bootoutOld
        {
            #expect(await harness.operations.contains(.cancelPermit))
        }
        #expect(!(await harness.operations.contains(.writeNewDescriptor)))
    }

    @Test("each post-bootout failure attempts exact rollback", arguments: [
        HandoffOperation.writeNewDescriptor,
        .bootstrapNew,
        .checkNewReadiness,
    ])
    fileprivate func postBootoutFailure(step: HandoffOperation) async throws {
        let harness = HandoffHarness(failing: step)
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack = result else {
            Issue.record("expected successful rollback for \(step)")
            return
        }
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        #expect(await harness.operations.contains(.restoreOldDescriptor))
        #expect(await harness.operations.contains(.checkOldReadiness))
    }

    @Test("reported old bootout failure restores vN when launchd already removed it")
    func ambiguousOldBootoutFailureRestoresOld() async throws {
        let harness = HandoffHarness(failingAfterEffect: .bootoutOld)
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack(let activation, let readiness) = result else {
            Issue.record("expected exact rollback after ambiguous old bootout")
            return
        }
        #expect(activation.stage == .bootoutOldDescriptor)
        #expect(readiness == harness.oldReadiness)
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        #expect(!(await harness.operations.contains(.cancelPermit)))
        #expect(await harness.operations.contains(.restoreOldDescriptor))
    }

    @Test("reported new bootout failure restores vN when launchd already removed vN+1")
    func ambiguousNewBootoutFailureRestoresOld() async throws {
        let harness = HandoffHarness(
            failing: [.checkNewReadiness],
            failingAfterEffect: .bootoutNew
        )
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rolledBack(let activation, let readiness) = result else {
            Issue.record("expected exact rollback after ambiguous new bootout")
            return
        }
        #expect(activation.stage == .proveNewReadiness)
        #expect(readiness == harness.oldReadiness)
        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        #expect(await harness.operations.contains(.restoreOldDescriptor))
    }

    @Test("rollback step failures are typed and never accepted as activation", arguments: [
        HandoffOperation.bootoutNew,
        .restoreOldDescriptor,
        .bootstrapOld,
        .checkOldReadiness,
    ])
    fileprivate func rollbackFailure(step: HandoffOperation) async throws {
        let harness = HandoffHarness(failing: [.checkNewReadiness, step])
        let coordinator = harness.coordinator()

        let result = try await coordinator.activateStagedPairIfIdle()

        guard case .rollbackFailed(let activation, let rollback) = result else {
            Issue.record("expected typed rollback failure for \(step)")
            return
        }
        #expect(activation.stage == .proveNewReadiness)
        #expect(rollback.stage.isRollbackStage)
    }

    @Test("private kernel lock excludes an independent service controller")
    func serviceControlLockIsCrossProcess() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-service-handoff-lock-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let descriptor = try #require(
            BackendServiceDescriptor(bundleIdentifier: "com.cmuxterm.test.handoff-lock")
        )
        let runtimePaths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: UInt32(geteuid()),
            homeDirectoryURL: home
        )
        try FileManager.default.createDirectory(
            at: runtimePaths.serviceInstallationRootURL,
            withIntermediateDirectories: true
        )
        let lock = SystemBackendServiceHandoffLock(
            runtimePaths: runtimePaths,
            expectedUserID: UInt32(geteuid())
        )

        let lease = try await lock.acquire()
        let lockURL = runtimePaths.serviceInstallationRootURL
            .appendingPathComponent(".service-control.lock", isDirectory: false)
        let contender = open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(contender >= 0)
        guard contender >= 0 else {
            await lease.release()
            return
        }
        defer { close(contender) }

        let contested = flock(contender, LOCK_EX | LOCK_NB)
        let contestedError = errno
        #expect(contested == -1)
        #expect(contestedError == EWOULDBLOCK)

        await lease.release()
        #expect(flock(contender, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contender, LOCK_UN) == 0)
    }

    @Test("coordinator lifetime and normal app exit never unregister the service")
    func deinitDoesNotTearDownService() async throws {
        let harness = HandoffHarness(preparation: .deferredNotIdle(.fixture(canonicalSurfaces: 1)))
        var coordinator: BackendServiceHandoffCoordinator? = harness.coordinator()
        _ = try await coordinator?.activateStagedPairIfIdle()
        coordinator = nil

        #expect(await harness.activeDescriptor == harness.oldDescriptor)
        #expect(!(await harness.operations.contains(.bootoutOld)))
        #expect(!(await harness.operations.contains(.unregister)))
    }
}

fileprivate enum HandoffOperation: Hashable, Sendable {
    case stageTarget
    case loadActiveDescriptor
    case connectCoordinator
    case preparePermit
    case cancelPermit
    case closeCoordinator
    case acquireLock
    case releaseLock
    case revalidatePermit
    case bootoutOld
    case writeNewDescriptor
    case bootstrapNew
    case checkNewReadiness
    case bootoutNew
    case restoreOldDescriptor
    case bootstrapOld
    case checkOldReadiness
    case unregister
}

private actor HandoffHarness: BackendServiceHandoffRegistering,
    BackendServiceHandoffConnecting,
    BackendServiceHandoffLocking,
    BackendServiceReadinessChecking
{
    nonisolated let oldPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "1", count: 64))
    nonisolated let newPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "2", count: 64))
    nonisolated let racingPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "3", count: 64))
    nonisolated let oldReadiness = BackendServiceReadiness.fixture(daemon: "11111111-1111-4111-8111-111111111111")
    nonisolated let newReadiness = BackendServiceReadiness.fixture(daemon: "22222222-2222-4222-8222-222222222222")
    nonisolated let oldDescriptor: BackendServiceHandoffLaunchDescriptor
    nonisolated let newDescriptor: BackendServiceHandoffLaunchDescriptor
    nonisolated let racingDescriptor: BackendServiceHandoffLaunchDescriptor
    nonisolated let permit: BackendServiceHandoffPermit

    private(set) var operations: [HandoffOperation] = []
    private(set) var activeDescriptor: BackendServiceHandoffLaunchDescriptor?
    private(set) var restoredPropertyList: Data?
    private var failures: Set<HandoffOperation>
    private var preparation: BackendServiceHandoffPreparation
    private var pairForNextReadiness: BackendServiceInstalledPair?
    private var activeReplacementOnLock: BackendServiceHandoffLaunchDescriptor?
    private var activeReplacementBeforeRollback: BackendServiceHandoffLaunchDescriptor?
    private var failureAfterBootoutEffect: HandoffOperation?

    init(
        failing: HandoffOperation? = nil,
        failingAfterEffect: HandoffOperation? = nil,
        preparation: BackendServiceHandoffPreparation? = nil
    ) {
        failures = Set(failing.map { [$0] } ?? [])
        failureAfterBootoutEffect = failingAfterEffect
        let oldPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "1", count: 64))
        let newPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "2", count: 64))
        let racingPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "3", count: 64))
        oldDescriptor = .fixture(pair: oldPair, marker: "exact-old-plist")
        newDescriptor = .fixture(pair: newPair, marker: "exact-new-plist")
        racingDescriptor = .fixture(pair: racingPair, marker: "racing-plist")
        activeDescriptor = oldDescriptor
        let defaultPermit = BackendServiceHandoffPermit.fixture(
            source: oldPair.buildID,
            target: newPair.buildID
        )
        let selectedPreparation = preparation ?? .prepared(defaultPermit)
        switch selectedPreparation {
        case .prepared(let prepared):
            permit = prepared
        case .deferredNotIdle:
            permit = defaultPermit
        }
        self.preparation = selectedPreparation
    }

    init(
        failing: Set<HandoffOperation>,
        failingAfterEffect: HandoffOperation? = nil
    ) {
        failures = failing
        failureAfterBootoutEffect = failingAfterEffect
        let oldPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "1", count: 64))
        let newPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "2", count: 64))
        let racingPair = BackendServiceInstalledPair.fixture(buildID: String(repeating: "3", count: 64))
        oldDescriptor = .fixture(pair: oldPair, marker: "exact-old-plist")
        newDescriptor = .fixture(pair: newPair, marker: "exact-new-plist")
        racingDescriptor = .fixture(pair: racingPair, marker: "racing-plist")
        activeDescriptor = oldDescriptor
        permit = .fixture(source: oldPair.buildID, target: newPair.buildID)
        preparation = .prepared(permit)
    }

    nonisolated func coordinator() -> BackendServiceHandoffCoordinator {
        BackendServiceHandoffCoordinator(
            registration: self,
            connection: self,
            lock: self,
            readinessChecker: self
        )
    }

    func replaceActiveWhenLockAcquired(with descriptor: BackendServiceHandoffLaunchDescriptor) {
        activeReplacementOnLock = descriptor
    }

    func replaceActiveBeforeRollback(with descriptor: BackendServiceHandoffLaunchDescriptor) {
        activeReplacementBeforeRollback = descriptor
    }

    func prepareBundledPair() throws -> BackendServiceInstalledPair {
        try record(.stageTarget)
        return newPair
    }

    func activeHandoffDescriptor() throws -> BackendServiceHandoffLaunchDescriptor? {
        try record(.loadActiveDescriptor)
        if operations.contains(.checkNewReadiness), let replacement = activeReplacementBeforeRollback {
            activeDescriptor = replacement
            activeReplacementBeforeRollback = nil
        }
        return activeDescriptor
    }

    func bootoutExact(_ descriptor: BackendServiceHandoffLaunchDescriptor) throws {
        let operation: HandoffOperation = descriptor.pair == oldPair ? .bootoutOld : .bootoutNew
        try record(operation)
        guard activeDescriptor == descriptor else {
            throw BackendServiceHandoffFailure(stage: .revalidateNewDescriptor, detail: "descriptor changed")
        }
        activeDescriptor = nil
        if failureAfterBootoutEffect == operation {
            throw HarnessFailure(operation: operation)
        }
    }

    func writeHandoffDescriptor(for pair: BackendServiceInstalledPair) throws
        -> BackendServiceHandoffLaunchDescriptor
    {
        try record(.writeNewDescriptor)
        #expect(pair == newPair)
        return newDescriptor
    }

    func restoreHandoffDescriptor(_ descriptor: BackendServiceHandoffLaunchDescriptor) throws {
        try record(.restoreOldDescriptor)
        restoredPropertyList = descriptor.propertyListData
    }

    func bootstrapExact(_ descriptor: BackendServiceHandoffLaunchDescriptor) throws {
        let operation: HandoffOperation = descriptor.pair == oldPair ? .bootstrapOld : .bootstrapNew
        try record(operation)
        activeDescriptor = descriptor
    }

    func connect(trustedPair: BackendServiceInstalledPair) throws {
        try record(.connectCoordinator)
        #expect(trustedPair == oldPair)
    }

    func prepare(targetBuildID: String) throws -> BackendServiceHandoffPreparation {
        try record(.preparePermit)
        #expect(targetBuildID == newPair.buildID)
        return preparation
    }

    func revalidate(_ permit: BackendServiceHandoffPermit) throws {
        try record(.revalidatePermit)
        #expect(permit == self.permit)
    }

    func cancel(_ permit: BackendServiceHandoffPermit) throws {
        try record(.cancelPermit)
        #expect(permit == self.permit)
    }

    func close() {
        operations.append(.closeCoordinator)
    }

    func acquire() throws -> any BackendServiceHandoffLockLease {
        try record(.acquireLock)
        if let replacement = activeReplacementOnLock {
            activeDescriptor = replacement
            activeReplacementOnLock = nil
        }
        return HarnessLockLease(harness: self)
    }

    func checkReadiness(trustedPair: BackendServiceInstalledPair) throws -> BackendServiceReadiness {
        pairForNextReadiness = trustedPair
        let operation: HandoffOperation = trustedPair == oldPair ? .checkOldReadiness : .checkNewReadiness
        try record(operation)
        return trustedPair == oldPair ? oldReadiness : newReadiness
    }

    func releaseLock() {
        operations.append(.releaseLock)
    }

    private func record(_ operation: HandoffOperation) throws {
        operations.append(operation)
        let shouldFail = failures.contains(operation)
            && (operation != .loadActiveDescriptor
                || operations.filter { $0 == .loadActiveDescriptor }.count >= 2)
        if shouldFail {
            throw HarnessFailure(operation: operation)
        }
    }
}

private struct HarnessLockLease: BackendServiceHandoffLockLease, Sendable {
    let harness: HandoffHarness

    func release() async {
        await harness.releaseLock()
    }
}

private struct HarnessFailure: Error, Sendable {
    let operation: HandoffOperation
}

private extension BackendServiceHandoffFailure.Stage {
    var isRollbackStage: Bool {
        switch self {
        case .revalidateNewDescriptor, .bootoutNewDescriptor, .restoreOldDescriptor,
             .bootstrapOldDescriptor, .proveOldReadiness:
            true
        default:
            false
        }
    }
}

private extension BackendServiceHandoffBlockers {
    static func fixture(canonicalSurfaces: UInt64) -> Self {
        .init(
            canonicalSurfaces: canonicalSurfaces,
            pendingTerminalLaunches: 0,
            presentations: 0,
            projectionStates: 0,
            terminalAuthorities: 0,
            rendererPresentations: 0,
            rendererWorkers: 0,
            pendingRendererRemovals: 0,
            rendererReleaseRoutes: 0,
            browserRuntime: false,
            frontendNativeBrowserRuntimes: 0,
            remoteExternalProducerRuntimes: 0,
            sidebarPluginRuntime: false,
            agentRecords: 0,
            unresolvedDurableMutation: false,
            unresolvedLaunchAttempts: 0,
            durableStorageDegraded: false
        )
    }
}

private extension BackendServiceInstalledPair {
    static func fixture(buildID: String) -> Self {
        let root = URL(fileURLWithPath: "/immutable/\(buildID)", isDirectory: true)
        return .init(
            buildID: buildID,
            installationDirectoryURL: root,
            backendExecutableURL: root.appendingPathComponent("cmux-terminal-backend"),
            rendererExecutableURL: root.appendingPathComponent("cmux-terminal-renderer"),
            manifestURL: root.appendingPathComponent("pair-manifest.json")
        )
    }
}

private extension BackendServiceHandoffLaunchDescriptor {
    static func fixture(pair: BackendServiceInstalledPair, marker: String) -> Self {
        .init(pair: pair, propertyListData: Data(marker.utf8))
    }
}

private extension BackendServiceHandoffPermit {
    static func fixture(source: String, target: String) -> Self {
        .init(
            capability: String(repeating: "a", count: 64),
            ownerConnectionID: UUID(),
            authority: BackendAuthority(
                daemonInstanceID: DaemonInstanceID(
                    rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
                ),
                sessionID: SessionID(
                    rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
                )
            ),
            session: "cmux",
            sourceBuildID: source,
            targetBuildID: target,
            topologyRevision: 0,
            canonicalTopologyRevision: 0,
            durableStorage: .init(
                state: .healthy,
                incidentID: nil,
                failurePhase: nil,
                failureResolution: nil,
                unresolvedMutation: false,
                unresolvedLaunchAttempts: 0
            )
        )
    }
}

private extension BackendServiceReadiness {
    static func fixture(daemon: String) -> Self {
        let daemonID = DaemonInstanceID(rawValue: UUID(uuidString: daemon)!)
        let sessionID = SessionID(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        let peer = BackendPeerIdentity(
            processID: daemonID == DaemonInstanceID(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) ? 41 : 42,
            userID: 501,
            auditToken: BackendAuditToken(
                word0: 1, word1: 2, word2: 3, word3: 4,
                word4: 5, word5: 6, word6: 7, word7: 8
            )
        )
        return .init(
            authority: BackendAuthority(daemonInstanceID: daemonID, sessionID: sessionID),
            session: "cmux",
            processID: peer.processID,
            userID: peer.userID,
            peerIdentity: peer,
            peerTrust: BackendPeerTrustEvidence(
                signingIdentifier: "com.cmuxterm.cmux-terminal-backend",
                teamIdentifier: nil,
                executableURL: URL(fileURLWithPath: "/immutable/backend"),
                processIDVersion: 1
            ),
            topologyRevision: 0,
            compatibility: .readWrite(BackendReadWriteCompatibility(
                clientProtocolRange: 9 ... 9,
                serverProtocolRange: 9 ... 9,
                negotiatedProtocol: 9,
                requiredCapabilities: ["service-handoff-v1"]
            ))
        )
    }
}

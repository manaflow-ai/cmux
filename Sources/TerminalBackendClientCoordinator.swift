import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalBackendService
import CmuxTerminalRenderProtocol
import Darwin
import Dispatch
import Foundation

struct TerminalBackendRendererWorkerEpoch: Hashable, Sendable {
    let daemonInstanceID: UUID
    let rendererEpoch: UInt64
}

struct TerminalBackendRendererWorkerProcessIdentity: Hashable, Sendable {
    let epoch: TerminalBackendRendererWorkerEpoch
    let processID: pid_t
    let processInstanceToken: BackendRendererProcessInstanceToken
}

final class TerminalBackendRendererWorkerExitFence: @unchecked Sendable {
    let completion: Task<Void, Never>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var finished = false

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        completion = Task {
            for await _ in pair.stream { return }
        }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.yield(())
        continuation.finish()
    }
}

struct TerminalBackendRendererWorkerExitLedger: Sendable {
    enum Registration: Equatable, Sendable {
        case installed
        case existing
        case conflict(TerminalBackendRendererWorkerProcessIdentity)
    }

    private struct Entry: Sendable {
        let identity: TerminalBackendRendererWorkerProcessIdentity
        var exited: Bool
        let fence: TerminalBackendRendererWorkerExitFence
    }

    static let maximumRetainedExitedEntries = 4_096
    private var entries: [TerminalBackendRendererWorkerEpoch: Entry] = [:]
    private var exitedOrder: [TerminalBackendRendererWorkerEpoch] = []
    private var exitedOrderHead = 0

    mutating func register(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) -> Registration {
        if let entry = entries[identity.epoch] {
            return entry.identity == identity ? .existing : .conflict(entry.identity)
        }
        entries[identity.epoch] = Entry(
            identity: identity,
            exited: false,
            fence: TerminalBackendRendererWorkerExitFence()
        )
        return .installed
    }

    mutating func markExited(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) -> Bool {
        guard var entry = entries[identity.epoch],
              entry.identity == identity,
              !entry.exited else { return false }
        entry.exited = true
        entries[identity.epoch] = entry
        entry.fence.finish()
        exitedOrder.append(identity.epoch)
        trimExitedEntries()
        return true
    }

    func identity(
        for epoch: TerminalBackendRendererWorkerEpoch
    ) -> TerminalBackendRendererWorkerProcessIdentity? {
        entries[epoch]?.identity
    }

    func hasExited(_ epoch: TerminalBackendRendererWorkerEpoch) -> Bool? {
        entries[epoch]?.exited
    }

    func fence(
        for epoch: TerminalBackendRendererWorkerEpoch
    ) -> TerminalBackendRendererWorkerExitFence? {
        entries[epoch]?.fence
    }

    mutating func remove(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) {
        guard entries[identity.epoch]?.identity == identity else { return }
        entries.removeValue(forKey: identity.epoch)
    }

    var entryCount: Int { entries.count }
    var activeFenceCount: Int { entries.values.lazy.filter { !$0.exited }.count }

    private mutating func trimExitedEntries() {
        while exitedOrder.count - exitedOrderHead > Self.maximumRetainedExitedEntries {
            let epoch = exitedOrder[exitedOrderHead]
            exitedOrderHead += 1
            if entries[epoch]?.exited == true {
                entries.removeValue(forKey: epoch)
            }
        }
        if exitedOrderHead >= Self.maximumRetainedExitedEntries {
            exitedOrder.removeFirst(exitedOrderHead)
            exitedOrderHead = 0
        }
    }
}

enum TerminalBackendRendererWorkerExitRegistration: Equatable, Sendable {
    case watching
    case alreadyExited
    case unverifiable
}

protocol TerminalBackendRendererWorkerExitMonitoring: Sendable {
    func register(
        _ identity: TerminalBackendRendererWorkerProcessIdentity,
        onExit: @escaping @Sendable (TerminalBackendRendererWorkerProcessIdentity) -> Void
    ) -> TerminalBackendRendererWorkerExitRegistration
}

/// Activates NOTE_EXIT first, then verifies the PID still names the exact
/// public-kernel process start tuple supplied by cmuxd.
final class TerminalBackendRendererWorkerExitMonitor:
    TerminalBackendRendererWorkerExitMonitoring,
    @unchecked Sendable
{
    typealias ExitHandler = @Sendable (
        TerminalBackendRendererWorkerProcessIdentity
    ) -> Void

    private struct Registration {
        let source: DispatchSourceProcess
        let handler: ExitHandler
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.cmux.renderer-worker-exit-monitor",
        qos: .userInitiated
    )
    private var registrations: [
        TerminalBackendRendererWorkerProcessIdentity: Registration
    ] = [:]

    func register(
        _ identity: TerminalBackendRendererWorkerProcessIdentity,
        onExit: @escaping ExitHandler
    ) -> TerminalBackendRendererWorkerExitRegistration {
        lock.lock()
        guard registrations[identity] == nil else {
            lock.unlock()
            return .watching
        }
        let source = DispatchSource.makeProcessSource(
            identifier: identity.processID,
            eventMask: .exit,
            queue: queue
        )
        registrations[identity] = Registration(source: source, handler: onExit)
        source.setEventHandler { [weak self] in
            self?.processExited(identity)
        }
        source.activate()
        lock.unlock()

        switch Self.currentProcessInstanceToken(processID: identity.processID) {
        case .exact(let token) where token == identity.processInstanceToken:
            return .watching
        case .exact, .missing:
            cancel(identity)
            return .alreadyExited
        case .unverifiable:
            cancel(identity)
            return .unverifiable
        }
    }

    private enum ProcessLookup {
        case exact(BackendRendererProcessInstanceToken)
        case missing
        case unverifiable
    }

    private static func currentProcessInstanceToken(processID: pid_t) -> ProcessLookup {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        errno = 0
        let size = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        if size == expectedSize, info.pbi_pid == UInt32(processID) {
            return .exact(BackendRendererProcessInstanceToken(
                startTimeSeconds: info.pbi_start_tvsec,
                startTimeMicroseconds: info.pbi_start_tvusec
            ))
        }
        if size <= 0, errno == ESRCH {
            return .missing
        }
        if size <= 0 {
            errno = 0
            if Darwin.kill(processID, 0) != 0, errno == ESRCH {
                return .missing
            }
        }
        return .unverifiable
    }

    private func cancel(_ identity: TerminalBackendRendererWorkerProcessIdentity) {
        lock.lock()
        let registration = registrations.removeValue(forKey: identity)
        lock.unlock()
        registration?.source.cancel()
    }

    private func processExited(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) {
        lock.lock()
        let registration = registrations.removeValue(forKey: identity)
        lock.unlock()
        guard let registration else { return }
        registration.source.cancel()
        registration.handler(identity)
    }

    deinit {
        lock.lock()
        let sources = registrations.values.map(\.source)
        registrations.removeAll()
        lock.unlock()
        for source in sources {
            source.cancel()
        }
    }
}

/// Process-wide owner of trusted backend connection replacement and terminal commands.
actor TerminalBackendClientCoordinator:
    TerminalBackendClient,
    TerminalBackendProjectionStateServing,
    TerminalBackendTopologyMutating,
    TerminalBackendExternalTerminalServing,
    TerminalBackendRemoteTmuxProducerSourceServing,
    TerminalBackendFrontendNativeBrowserServing,
    TerminalBackendFrontendConnectionRecovering,
    BackendTerminalCompatibilityInputAuthority
{
    typealias ReadinessProvider = @Sendable () async throws -> BackendServiceBootstrapResult
    typealias SessionFactory = @Sendable (BackendServiceReadiness) -> any TerminalBackendSessionServing
    typealias CompatibilityReporter = @Sendable (BackendCompatibilityResult?) async -> Void

    private let readinessProvider: ReadinessProvider
    private let sessionFactory: SessionFactory
    private let reconnectPolicy: TerminalBackendReconnectPolicy
    private let compatibilityReporter: CompatibilityReporter
    private let screenTextLimiter = TerminalBackendScreenTextLimiter()

    private struct PendingTerminalReceiptAcknowledgement: Hashable, Sendable {
        let surfaceID: SurfaceID
        let requestID: UUID
    }

    private struct RendererPresentationRecord: Sendable {
        let binding: TerminalBackendTerminalBinding
        let backendID: PresentationID
        var canonicalGeneration: UInt64
        var descriptor: TerminalBackendPresentationDescriptor
        var receipt: BackendRendererPresentationReceipt?
        var ready: BackendRendererPresentationReady?
        var workerIdentity: TerminalBackendRendererWorkerProcessIdentity?
        var removalPending: Bool
    }

    private struct RendererConfigurationResult: Sendable {
        let attachment: TerminalBackendRendererAttachment?
        let activation: TerminalBackendRendererActivation?
    }

    /// Exact canonical placement for a non-rendering terminal input owner.
    /// Numeric handles are included so a delete/recreate cannot masquerade as
    /// the same authority merely by reusing stable UUIDs.
    private struct TerminalInputTopologyLocation: Equatable, Sendable {
        let workspaceHandle: UInt64
        let workspaceID: WorkspaceID
        let screenHandle: UInt64
        let screenID: ScreenID
        let paneHandle: UInt64
        let paneID: PaneID
        let surfaceHandle: UInt64
        let surfaceID: SurfaceID

        var presentationView: BackendPresentationView {
            BackendPresentationView(
                workspaceID: workspaceID,
                screenID: screenID,
                paneID: paneID,
                surfaceID: surfaceID
            )
        }
    }

    private struct TerminalInputOwnerRecord: Equatable, Sendable {
        let connectionAttemptID: UUID
        let authority: BackendAuthority
        let location: TerminalInputTopologyLocation
        let presentationID: PresentationID
        let presentationGeneration: UInt64
        var inputLeaseGeneration: UInt64
    }

    private struct TerminalCompatibilityGrantRecord: Equatable, Sendable {
        let delegateIdentity: BackendClientRegistrationIdentity
        let delegation: BackendTerminalInputDelegation
        let localDeadlineNanoseconds: UInt64
    }

    private struct PendingTerminalEnsure {
        let request: TerminalBackendTerminalRequest
        let continuation: CheckedContinuation<TerminalBackendTerminalBinding, any Error>
    }

    private struct TopologyRevisionWaiter {
        let authority: BackendAuthority
        let revision: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var connected: TerminalBackendConnectedSession?
    private var latestSnapshot: TopologySnapshot?
    private var latestActivitySnapshot: BackendTerminalActivitySnapshot?
    private var connectionSupervisorTask: Task<Void, Never>?
    private var connectionSupervisorID = UUID()
    private var connectionTask: Task<TerminalBackendConnectedSession, any Error>?
    private var connectionAttemptID = UUID()
    private var eventTask: Task<Void, Never>?
    private var terminalInputOwners: [SurfaceID: TerminalInputOwnerRecord] = [:]
    private var terminalCompatibilityGrants: [
        SurfaceID: [UUID: TerminalCompatibilityGrantRecord]
    ] = [:]
    private var activeTerminalInputOperations: Set<SurfaceID> = []
    private var terminalInputOperationWaiters: [
        SurfaceID: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var rendererPresentations: [UUID: RendererPresentationRecord] = [:]
    private var rendererRemovalRequests: Set<UUID> = []
    private var activeRendererPresentationOperations: Set<UUID> = []
    private var rendererPresentationOperationWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var rendererContinuations: [
        UUID: AsyncStream<TerminalBackendRendererEvent>.Continuation
    ] = [:]
    private var snapshotContinuations: [UUID: AsyncStream<TopologySnapshot>.Continuation] = [:]
    private var topologyContinuations: [
        UUID: AsyncStream<TerminalBackendTopologyStreamEvent>.Continuation
    ] = [:]
    private var activityContinuations: [
        UUID: AsyncStream<BackendTerminalActivitySnapshot>.Continuation
    ] = [:]
    private var pendingTerminalEnsures: [PendingTerminalEnsure] = []
    private var terminalEnsureFlushScheduled = false
    private var terminalRequestsAwaitingRecovery: Set<UUID> = []
    private var pendingTerminalReceiptAcknowledgements:
        Set<PendingTerminalReceiptAcknowledgement> = []
    private var topologyMutationInFlight = false
    private var topologyMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var topologyRevisionWaiters: [UUID: TopologyRevisionWaiter] = [:]
    private var frontendRecoveryGeneration: UUID?
    private var frontendRecoveryStartCount = 0
    private let rendererWorkerExitMonitor: any TerminalBackendRendererWorkerExitMonitoring
    private var rendererWorkerExitLedger = TerminalBackendRendererWorkerExitLedger()
    private let monotonicNowNanoseconds: @Sendable () -> UInt64

    private static let terminalInputOwnerTTLMilliseconds: UInt64 = 30_000
    private static let terminalCompatibilityGrantTTLMilliseconds: UInt64 = 10_000
    private static let terminalCompatibilityRefreshMarginMilliseconds: UInt64 = 2_000

    init(
        bootstrapCoordinator: BackendServiceBootstrapCoordinator,
        runtimePaths: BackendServiceRuntimePaths,
        registrationIdentity: BackendClientRegistrationIdentity,
        reconnectPolicy: TerminalBackendReconnectPolicy = .appStartup,
        rendererWorkerExitMonitor: any TerminalBackendRendererWorkerExitMonitoring =
            TerminalBackendRendererWorkerExitMonitor(),
        compatibilityReporter: @escaping CompatibilityReporter = { _ in }
    ) {
        readinessProvider = {
            try await bootstrapCoordinator.ensureRegistered()
        }
        sessionFactory = { readiness in
            BackendCanonicalSession(
                transport: UnixBackendTransport(path: runtimePaths.socketURL.path),
                expectation: BackendCanonicalSessionExpectation(
                    session: readiness.session,
                    authority: readiness.authority,
                    processID: readiness.processID,
                    peerIdentity: readiness.peerIdentity
                ),
                registrationIdentity: registrationIdentity
            )
        }
        self.reconnectPolicy = reconnectPolicy
        self.rendererWorkerExitMonitor = rendererWorkerExitMonitor
        self.compatibilityReporter = compatibilityReporter
        monotonicNowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
    }

    init(
        readinessProvider: @escaping ReadinessProvider,
        sessionFactory: @escaping SessionFactory,
        reconnectPolicy: TerminalBackendReconnectPolicy = .immediate,
        rendererWorkerExitMonitor: any TerminalBackendRendererWorkerExitMonitoring =
            TerminalBackendRendererWorkerExitMonitor(),
        monotonicNowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        compatibilityReporter: @escaping CompatibilityReporter = { _ in }
    ) {
        self.readinessProvider = readinessProvider
        self.sessionFactory = sessionFactory
        self.reconnectPolicy = reconnectPolicy
        self.rendererWorkerExitMonitor = rendererWorkerExitMonitor
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        self.compatibilityReporter = compatibilityReporter
    }

    deinit {
        connectionSupervisorTask?.cancel()
        connectionTask?.cancel()
        eventTask?.cancel()
    }

    func start() async {
        ensureConnectionSupervisor()
    }

    func authorizeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        replacing: BackendTerminalInputDelegation?
    ) async throws -> BackendTerminalInputDelegation {
        await acquireTerminalInputOperation(surfaceID)
        defer { releaseTerminalInputOperation(surfaceID) }

        let connection = try await connectedSession()
        let attemptID = connectionAttemptID
        try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
        var owner = try await stableTerminalInputOwner(
            surfaceID: surfaceID,
            binding: nil,
            connection: connection,
            attemptID: attemptID
        )
        let now = monotonicNowNanoseconds()
        let refreshThreshold = now.addingClamped(
            Self.terminalCompatibilityRefreshMarginMilliseconds
                .multipliedClamped(by: 1_000_000)
        )

        if let current = terminalCompatibilityGrants[surfaceID]?[delegateIdentity.clientUUID] {
            guard current.delegateIdentity == delegateIdentity else {
                throw BackendTerminalControlError.staleConnection
            }
            if let replacing, replacing != current.delegation {
                throw BackendTerminalControlError.staleLease
            }
            if current.localDeadlineNanoseconds > refreshThreshold {
                return current.delegation
            }

            terminalCompatibilityGrants[surfaceID]?.removeValue(
                forKey: delegateIdentity.clientUUID
            )
            if terminalCompatibilityGrants[surfaceID]?.isEmpty == true {
                terminalCompatibilityGrants.removeValue(forKey: surfaceID)
            }
            if now < current.localDeadlineNanoseconds {
                do {
                    try await connection.session.revokeTerminalInputDelegation(
                        surfaceID: surfaceID,
                        presentationID: owner.presentationID,
                        presentationGeneration: owner.presentationGeneration,
                        delegation: current.delegation
                    )
                } catch {
                    if connectionAttemptID == attemptID,
                       connected?.readiness == connection.readiness {
                        await invalidate(connection)
                    }
                    throw error
                }
            }
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            owner = try await stableTerminalInputOwner(
                surfaceID: surfaceID,
                binding: nil,
                connection: connection,
                attemptID: attemptID
            )
        }

        let grantStartedAt = monotonicNowNanoseconds()
        let delegation = try await connection.session.grantTerminalInputDelegation(
            surfaceID: surfaceID,
            presentationID: owner.presentationID,
            presentationGeneration: owner.presentationGeneration,
            delegateClientUUID: delegateIdentity.clientUUID,
            ttlMilliseconds: Self.terminalCompatibilityGrantTTLMilliseconds,
            scopes: [.text]
        )
        do {
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            if delegation.ownerLeaseGeneration != owner.inputLeaseGeneration {
                guard delegation.ownerLeaseGeneration > owner.inputLeaseGeneration,
                      terminalInputOwners[surfaceID] == owner else {
                    throw BackendProtocolError.peerIdentityMismatch
                }
                // The canonical session may renew the owner lease to ensure it
                // outlives this delegation. cmuxd atomically revokes every
                // grant from the previous lease generation; mirror that before
                // publishing the new grant.
                terminalCompatibilityGrants.removeValue(forKey: surfaceID)
                owner.inputLeaseGeneration = delegation.ownerLeaseGeneration
                terminalInputOwners[surfaceID] = owner
            }
            let currentLocation = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: nil,
                connection: connection
            )
            guard terminalInputOwners[surfaceID] == owner,
                  currentLocation == owner.location,
                  delegation.surfaceID == surfaceID,
                  delegation.delegateClientUUID == delegateIdentity.clientUUID,
                  delegation.delegateProcessInstanceUUID == delegateIdentity.processInstanceUUID,
                  delegation.ownerLeaseGeneration == owner.inputLeaseGeneration,
                  delegation.delegationID != .nilUUID,
                  delegation.delegationGeneration > 0,
                  delegation.expiresAtMilliseconds > 0,
                  delegation.nextSequence > 0,
                  delegation.scopes == [.text] else {
                throw BackendProtocolError.peerIdentityMismatch
            }
        } catch {
            try? await connection.session.revokeTerminalInputDelegation(
                surfaceID: surfaceID,
                presentationID: owner.presentationID,
                presentationGeneration: owner.presentationGeneration,
                delegation: delegation
            )
            throw error
        }
        let record = TerminalCompatibilityGrantRecord(
            delegateIdentity: delegateIdentity,
            delegation: delegation,
            localDeadlineNanoseconds: grantStartedAt.addingClamped(
                Self.terminalCompatibilityGrantTTLMilliseconds
                    .multipliedClamped(by: 1_000_000)
            )
        )
        terminalCompatibilityGrants[surfaceID, default: [:]][delegateIdentity.clientUUID] = record
        return delegation
    }

    func revokeTerminalCompatibilityInput(
        surfaceID: SurfaceID,
        delegateIdentity: BackendClientRegistrationIdentity,
        delegation: BackendTerminalInputDelegation
    ) async throws {
        await acquireTerminalInputOperation(surfaceID)
        defer { releaseTerminalInputOperation(surfaceID) }
        guard let current = terminalCompatibilityGrants[surfaceID]?[delegateIdentity.clientUUID]
        else {
            // Owner disconnect, topology retirement, and local expiry already
            // revoke the daemon authority represented by a stale callback.
            return
        }
        guard current.delegateIdentity == delegateIdentity,
              current.delegation == delegation else {
            throw BackendTerminalControlError.staleLease
        }
        terminalCompatibilityGrants[surfaceID]?.removeValue(forKey: delegateIdentity.clientUUID)
        if terminalCompatibilityGrants[surfaceID]?.isEmpty == true {
            terminalCompatibilityGrants.removeValue(forKey: surfaceID)
        }
        guard monotonicNowNanoseconds() < current.localDeadlineNanoseconds,
              let owner = terminalInputOwners[surfaceID],
              let connection = connected,
              owner.connectionAttemptID == connectionAttemptID,
              owner.authority == connection.readiness.authority else {
            return
        }
        do {
            try await connection.session.revokeTerminalInputDelegation(
                surfaceID: surfaceID,
                presentationID: owner.presentationID,
                presentationGeneration: owner.presentationGeneration,
                delegation: current.delegation
            )
        } catch {
            if connectionAttemptID == owner.connectionAttemptID,
               connected?.readiness == connection.readiness {
                await invalidate(connection)
            }
            throw error
        }
    }

    func rendererEvents() -> AsyncStream<TerminalBackendRendererEvent> {
        ensureConnectionSupervisor()
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            rendererContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRendererContinuation(identifier) }
            }
        }
    }

    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot> {
        ensureConnectionSupervisor()
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            snapshotContinuations[identifier] = continuation
            if let latestSnapshot {
                continuation.yield(latestSnapshot)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(identifier) }
            }
        }
    }

    func canonicalTopologyEvents() async throws -> AsyncStream<TerminalBackendTopologyStreamEvent> {
        ensureConnectionSupervisor()
        let identifier = UUID()
        // Every delta carries a complete replacement topology, so retaining the
        // newest state is sufficient and prevents a slow main actor from
        // permanently losing topology observation during a mutation burst.
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            topologyContinuations[identifier] = continuation
            if let latestSnapshot {
                continuation.yield(.snapshot(latestSnapshot))
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTopologyContinuation(identifier) }
            }
        }
    }

    func terminalActivitySnapshots() -> AsyncStream<BackendTerminalActivitySnapshot> {
        ensureConnectionSupervisor()
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            activityContinuations[identifier] = continuation
            if let latestActivitySnapshot {
                continuation.yield(latestActivitySnapshot)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeActivityContinuation(identifier) }
            }
        }
    }

    func disconnectFrontend() async {
        frontendRecoveryGeneration = nil
        await disconnectFrontendPreservingRecoveryGeneration()
    }

    /// Browser lease failures invalidate every connection-private claim. Keep
    /// one recovery generation active until a replacement session is usable so
    /// simultaneous failures cannot each tear down the process-wide frontend.
    func recoverFrontendConnection() async {
        guard frontendRecoveryGeneration == nil else { return }
        let generation = UUID()
        frontendRecoveryGeneration = generation
        frontendRecoveryStartCount += 1
        await disconnectFrontendPreservingRecoveryGeneration()
        guard frontendRecoveryGeneration == generation else { return }
        ensureConnectionSupervisor()
    }

    var debugFrontendRecoveryStartCount: Int {
        frontendRecoveryStartCount
    }

    private func disconnectFrontendPreservingRecoveryGeneration() async {
        connectionSupervisorID = UUID()
        connectionSupervisorTask?.cancel()
        connectionSupervisorTask = nil
        discardTerminalInputAuthorityState()
        connectionAttemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        latestSnapshot = nil
        failTopologyRevisionWaiters(BackendCanonicalSessionError.notConnected)
        let previous = connected
        connected = nil
        if let authority = previous?.readiness.authority {
            publishRenderer(.connectionLost(authority))
            publishTopology(.disconnected(authority))
        }
        await compatibilityReporter(nil)
        await previous?.session.close()
    }

    func createWorkspace(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-new-workspace",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            try await session.newWorkspace(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                name: name,
                launch: launch,
                columns: columns,
                rows: rows
            )
        }
    }

    func createTerminalTab(
        requestID: UUID,
        surfaceID: SurfaceID,
        in paneID: PaneID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-new-tab",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.newTerminalTab(
                expectation: expectation,
                paneID: paneID,
                surfaceID: surfaceID,
                launch: launch,
                columns: columns,
                rows: rows
            )
            guard placement.paneID == paneID, placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func createBrowserWorkspace(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        name: String?,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-new-browser-workspace",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.newBrowserWorkspace(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                name: name,
                url: url,
                columns: columns,
                rows: rows
            )
            guard placement.workspaceID == workspaceID,
                  placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func createBrowserTab(
        requestID: UUID,
        surfaceID: SurfaceID,
        in paneID: PaneID,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-new-browser-tab",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.newBrowserTab(
                expectation: expectation,
                paneID: paneID,
                surfaceID: surfaceID,
                url: url,
                columns: columns,
                rows: rows
            )
            guard placement.paneID == paneID,
                  placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func splitBrowserPane(
        requestID: UUID,
        surfaceID: SurfaceID,
        _ paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        url: URL,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw TerminalBackendTopologyMutationError.invalidSplitRatio(initialRatio)
        }
        return try await performCanonicalTopologyMutation(
            command: "canonical-split-browser-pane",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.splitBrowserPane(
                expectation: expectation,
                paneID: paneID,
                surfaceID: surfaceID,
                direction: direction,
                initialRatio: initialRatio,
                url: url,
                columns: columns,
                rows: rows
            )
            guard placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func materializeTerminal(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-materialize-terminal",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.materializeTerminal(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                launch: launch,
                columns: columns,
                rows: rows
            )
            guard placement.workspaceID == workspaceID,
                  placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func respawnTerminal(
        requestID: UUID,
        surfaceID: SurfaceID,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-respawn-terminal",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.respawnTerminal(
                expectation: expectation,
                surfaceID: surfaceID,
                launch: launch,
                columns: columns,
                rows: rows
            )
            guard placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func materializeExternalTerminal(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-materialize-external-terminal",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.materializeExternalTerminal(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                columns: columns,
                rows: rows,
                noReflow: noReflow,
                provenance: provenance
            )
            guard placement.workspaceID == workspaceID,
                  placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func newExternalWorkspace(
        requestID: UUID,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance,
        producerSource: BackendRemoteTmuxProducerSource
    ) async throws -> BackendSurfacePlacement {
        try await performCanonicalTopologyMutation(
            command: "canonical-new-external-workspace",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.newExternalWorkspace(
                expectation: expectation,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                columns: columns,
                rows: rows,
                noReflow: noReflow,
                provenance: provenance,
                producerSource: producerSource
            )
            guard placement.workspaceID == workspaceID,
                  placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func claimExternalTerminal(
        surfaceID: SurfaceID,
        requestID: UUID
    ) async throws -> BackendExternalTerminalClaimReceipt {
        let connection = try await connectedSession()
        return try await connection.session.claimExternalTerminal(
            surfaceID: surfaceID,
            requestID: requestID
        )
    }

    func resetExternalTerminal(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        seed: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        let connection = try await connectedSession()
        return try await connection.session.resetExternalTerminal(
            surfaceID: surfaceID,
            ownerGeneration: ownerGeneration,
            requestID: requestID,
            outputGeneration: outputGeneration,
            columns: columns,
            rows: rows,
            noReflow: noReflow,
            seed: seed
        )
    }

    func sendExternalTerminalOutput(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        outputGeneration: UInt64,
        sequence: UInt64,
        data: Data
    ) async throws -> BackendExternalTerminalOutputReceipt {
        let connection = try await connectedSession()
        return try await connection.session.sendExternalTerminalOutput(
            surfaceID: surfaceID,
            ownerGeneration: ownerGeneration,
            requestID: requestID,
            outputGeneration: outputGeneration,
            sequence: sequence,
            data: data
        )
    }

    func drainExternalTerminalEgress(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64
    ) async throws -> Data {
        let connection = try await connectedSession()
        return try await connection.session.drainExternalTerminalEgress(
            surfaceID: surfaceID,
            ownerGeneration: ownerGeneration
        )
    }

    func claimRemoteTmuxProducerSource(
        producerID: UUID,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource?
    ) async throws -> BackendRemoteTmuxProducerSourceClaimReceipt {
        let connection = try await connectedSession()
        return try await connection.session.claimRemoteTmuxProducerSource(
            producerID: producerID,
            requestID: requestID,
            source: source
        )
    }

    func updateRemoteTmuxProducerSource(
        producerID: UUID,
        ownerGeneration: UInt64,
        requestID: UUID,
        source: BackendRemoteTmuxProducerSource
    ) async throws -> BackendRemoteTmuxProducerSourceUpdateReceipt {
        let connection = try await connectedSession()
        return try await connection.session.updateRemoteTmuxProducerSource(
            producerID: producerID,
            ownerGeneration: ownerGeneration,
            requestID: requestID,
            source: source
        )
    }

    func claimFrontendNativeBrowser(
        surfaceID: SurfaceID,
        requestID: UUID,
        sourceURL: URL?
    ) async throws -> BackendFrontendNativeBrowserClaimReceipt {
        let connection = try await connectedSession()
        return try await connection.session.claimFrontendNativeBrowser(
            surfaceID: surfaceID,
            requestID: requestID,
            sourceURL: sourceURL
        )
    }

    func updateFrontendNativeBrowserSource(
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        requestID: UUID,
        sourceURL: URL
    ) async throws -> BackendFrontendNativeBrowserSourceReceipt {
        let connection = try await connectedSession()
        return try await connection.session.updateFrontendNativeBrowserSource(
            surfaceID: surfaceID,
            ownerGeneration: ownerGeneration,
            requestID: requestID,
            sourceURL: sourceURL
        )
    }

    func splitPane(
        requestID: UUID,
        surfaceID: SurfaceID,
        _ paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float,
        launch: BackendTerminalLaunch,
        columns: UInt16?,
        rows: UInt16?
    ) async throws -> BackendSurfacePlacement {
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw TerminalBackendTopologyMutationError.invalidSplitRatio(initialRatio)
        }
        return try await performCanonicalTopologyMutation(
            command: "canonical-split-pane",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.splitPane(
                expectation: expectation,
                paneID: paneID,
                surfaceID: surfaceID,
                direction: direction,
                initialRatio: initialRatio,
                launch: launch,
                columns: columns,
                rows: rows
            )
            guard placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func splitTab(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        around paneID: PaneID,
        direction: BackendSplitDirection,
        initialRatio: Float
    ) async throws -> BackendSurfacePlacement {
        guard initialRatio.isFinite, initialRatio > 0, initialRatio < 1 else {
            throw TerminalBackendTopologyMutationError.invalidSplitRatio(initialRatio)
        }
        return try await performCanonicalTopologyMutation(
            command: "canonical-split-tab",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.splitTab(
                expectation: expectation,
                surfaceID: surfaceID,
                paneID: paneID,
                direction: direction,
                initialRatio: initialRatio
            )
            guard placement.surfaceID == surfaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func closePane(
        requestID: UUID,
        _ paneID: PaneID
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-close-pane",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.closePane(expectation: expectation, paneID: paneID)
        }
    }

    func closeSurface(
        requestID: UUID,
        _ surfaceID: SurfaceID
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-close-surface",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.closeSurface(
                expectation: expectation,
                surfaceID: surfaceID
            )
        }
    }

    func closeWorkspace(
        requestID: UUID,
        _ workspaceID: WorkspaceID
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-close-workspace",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.closeWorkspace(
                expectation: expectation,
                workspaceID: workspaceID
            )
        }
    }

    func renameWorkspace(
        requestID: UUID,
        _ workspaceID: WorkspaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-rename-workspace",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.renameWorkspace(
                expectation: expectation,
                workspaceID: workspaceID,
                name: name
            )
        }
    }

    func renameSurface(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        name: String
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-rename-surface",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.renameSurface(
                expectation: expectation,
                surfaceID: surfaceID,
                name: name
            )
        }
    }

    func moveTab(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        to paneID: PaneID,
        index: Int
    ) async throws -> BackendTopologyMutationReceipt {
        let wireIndex = try topologyMutationIndex(index)
        return try await performCanonicalTopologyMutation(
            command: "canonical-move-tab",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.moveTab(
                expectation: expectation,
                surfaceID: surfaceID,
                paneID: paneID,
                index: wireIndex
            )
        }
    }

    func reorderTabs(
        requestID: UUID,
        in paneID: PaneID,
        surfaceIDs: [SurfaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-reorder-tabs",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.reorderTabs(
                expectation: expectation,
                paneID: paneID,
                surfaceIDs: surfaceIDs
            )
        }
    }

    func reorderWorkspaces(
        requestID: UUID,
        _ workspaceIDs: [WorkspaceID]
    ) async throws -> BackendTopologyMutationReceipt {
        try await performCanonicalTopologyMutation(
            command: "canonical-reorder-workspaces",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.reorderWorkspaces(
                expectation: expectation,
                workspaceIDs: workspaceIDs
            )
        }
    }

    func moveTabToNewWorkspace(
        requestID: UUID,
        _ surfaceID: SurfaceID,
        workspaceID: WorkspaceID,
        name: String?,
        index: Int?
    ) async throws -> BackendSurfacePlacement {
        let wireIndex: UInt64?
        if let index {
            wireIndex = try topologyMutationIndex(index)
        } else {
            wireIndex = nil
        }
        return try await performCanonicalTopologyMutation(
            command: "canonical-move-tab-to-new-workspace",
            requestID: requestID,
            receipt: \BackendSurfacePlacement.receipt
        ) { session, expectation in
            let placement = try await session.moveTabToNewWorkspace(
                expectation: expectation,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                name: name,
                index: wireIndex
            )
            guard placement.surfaceID == surfaceID,
                  placement.workspaceID == workspaceID else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            return placement
        }
    }

    func setSplitRatio(
        requestID: UUID,
        around paneID: PaneID,
        direction: BackendSplitDirection,
        ratio: Float
    ) async throws -> BackendTopologyMutationReceipt {
        guard ratio.isFinite, ratio > 0, ratio < 1 else {
            throw TerminalBackendTopologyMutationError.invalidSplitRatio(ratio)
        }
        return try await performCanonicalTopologyMutation(
            command: "canonical-set-split-ratio",
            requestID: requestID,
            receipt: { $0 }
        ) { session, expectation in
            try await session.setSplitRatio(
                expectation: expectation,
                paneID: paneID,
                direction: direction,
                ratio: ratio
            )
        }
    }

    func claimProjectionState(
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        let connection = try await connectedSession()
        return try await connection.session.claimProjectionState(
            logicalPresentationID: logicalPresentationID
        )
    }

    func updateProjectionStates(
        _ projections: [BackendProjectionStateUpdate]
    ) async throws -> [BackendProjectionState] {
        let connection = try await connectedSession()
        return try await connection.session.updateProjectionStates(projections)
    }

    func releaseProjectionState(
        logicalPresentationID: UUID,
        claimID: UUID,
        expectedGeneration: UInt64
    ) async throws {
        let connection = try await connectedSession()
        try await connection.session.releaseProjectionState(
            logicalPresentationID: logicalPresentationID,
            claimID: claimID,
            expectedGeneration: expectedGeneration
        )
    }

    func listProjectionStates() async throws -> [BackendProjectionState] {
        let connection = try await connectedSession()
        return try await connection.session.listProjectionStates()
    }

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding {
        try await withCheckedThrowingContinuation { continuation in
            pendingTerminalEnsures.append(PendingTerminalEnsure(
                request: request,
                continuation: continuation
            ))
            guard !terminalEnsureFlushScheduled else { return }
            terminalEnsureFlushScheduled = true
            Task {
                await Task.yield()
                await self.flushPendingTerminalEnsures()
            }
        }
    }

    private func flushPendingTerminalEnsures() async {
        let maximumBatchSize = 1_024
        while !pendingTerminalEnsures.isEmpty {
            let pending = pendingTerminalEnsures
            pendingTerminalEnsures.removeAll(keepingCapacity: true)
            for lowerBound in stride(from: 0, to: pending.count, by: maximumBatchSize) {
                let upperBound = min(lowerBound + maximumBatchSize, pending.count)
                await executeTerminalEnsureBatch(Array(pending[lowerBound ..< upperBound]))
            }
        }
        terminalEnsureFlushScheduled = false
    }

    private func executeTerminalEnsureBatch(_ pending: [PendingTerminalEnsure]) async {
        do {
            let connection = try await connectedSession()
            let requests = pending.map { item in
                let request = item.request
                return BackendEnsureTerminalRequest(
                    workspaceID: WorkspaceID(rawValue: request.appWorkspaceID),
                    surfaceID: SurfaceID(rawValue: request.appSurfaceID),
                    workingDirectory: request.workingDirectory,
                    command: request.command,
                    arguments: request.arguments,
                    environment: request.environment,
                    initialInput: request.initialInput,
                    waitAfterCommand: request.waitAfterCommand,
                    columns: request.columns,
                    rows: request.rows
                )
            }
            let placements = try await connection.session.ensureTerminals(requests)
            guard placements.count == pending.count else {
                await invalidate(connection)
                throw BackendProtocolError.peerIdentityMismatch
            }
            var bindings: [TerminalBackendTerminalBinding] = []
            bindings.reserveCapacity(pending.count)
            for (item, placement) in zip(pending, placements) {
                let request = item.request
                guard placement.workspaceID.rawValue == request.appWorkspaceID,
                      placement.surfaceID.rawValue == request.appSurfaceID else {
                    await invalidate(connection)
                    throw BackendProtocolError.peerIdentityMismatch
                }
                bindings.append(TerminalBackendTerminalBinding(
                    authority: connection.readiness.authority,
                    appWorkspaceID: request.appWorkspaceID,
                    appSurfaceID: request.appSurfaceID,
                    workspaceHandle: placement.workspace,
                    workspaceID: placement.workspaceID,
                    surfaceHandle: placement.surface,
                    surfaceID: placement.surfaceID,
                    columns: request.columns,
                    rows: request.rows,
                    created: placement.created
                ))
            }
            for (item, binding) in zip(pending, bindings) {
                item.continuation.resume(returning: binding)
            }
        } catch {
            for item in pending {
                item.continuation.resume(throwing: error)
            }
        }
    }

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome {
        let connection = try await connectedSession(for: binding)
        let inputConnectionAttemptID = connectionAttemptID
        var outcome = TerminalBackendMutationOutcome()
        switch mutation {
        case .input(.text(let input)):
            switch try await connection.session.terminalControlProtocol() {
            case .legacyV8:
                try await connection.session.sendTerminalText(
                    surface: binding.surfaceHandle,
                    text: input.text,
                    paste: input.kind == .paste
                )
            case .leasedV9:
                _ = try await sendLeasedTerminalInput(
                    requestID: requestID,
                    input: .text(input.text, paste: input.kind == .paste),
                    binding: binding,
                    connection: connection,
                    attemptID: inputConnectionAttemptID
                )
            }
        case .input(.key(let key)):
            let event = BackendTerminalKeyEvent(
                key: key.key,
                modifiers: key.modifiers.rawValue,
                consumedModifiers: key.consumedModifiers.rawValue,
                text: key.text ?? "",
                unshiftedCodepoint: key.unshiftedCodepoint,
                action: key.action.backendAction
            )
            switch try await connection.session.terminalControlProtocol() {
            case .legacyV8:
                _ = try await connection.session.sendTerminalKey(
                    surface: binding.surfaceHandle,
                    event: event
                )
            case .leasedV9:
                _ = try await sendLeasedTerminalInput(
                    requestID: requestID,
                    input: .key(event),
                    binding: binding,
                    connection: connection,
                    attemptID: inputConnectionAttemptID
                )
            }
        case .input(.namedKey(let key)):
            switch try await connection.session.terminalControlProtocol() {
            case .legacyV8:
                try await connection.session.sendTerminalNamedKey(
                    surface: binding.surfaceHandle,
                    key: key
                )
            case .leasedV9:
                _ = try await sendLeasedTerminalInput(
                    requestID: requestID,
                    input: .namedKey(key),
                    binding: binding,
                    connection: connection,
                    attemptID: inputConnectionAttemptID
                )
            }
        case .mouse(let mouse):
            let record = try rendererControlRecord(
                presentation: presentation,
                binding: binding
            )
            guard let receipt = record.receipt,
                  let geometry = rendererGeometry(record) else {
                throw TerminalBackendClientError.rendererNotReady
            }
            switch try await connection.session.terminalControlProtocol() {
            case .legacyV8:
                _ = try await connection.session.sendTerminalMouse(
                    surface: binding.surfaceHandle,
                    event: BackendTerminalMouseEvent(
                        action: mouse.action.backendAction,
                        button: mouse.button?.backendButton,
                        modifiers: mouse.modifiers.rawValue,
                        x: mouse.xPixels,
                        y: mouse.yPixels,
                        viewportWidth: receipt.width,
                        viewportHeight: receipt.height,
                        cellWidth: geometry.cellWidth,
                        cellHeight: geometry.cellHeight,
                        padding: geometry.padding,
                        anyButtonPressed: mouse.anyButtonPressed,
                        clickCount: mouse.clickCount
                    )
                )
            case .leasedV9:
                guard let cellEvent = BackendTerminalCellMouseEvent(
                    action: mouse.action.backendAction,
                    button: mouse.button?.backendButton,
                    modifiers: mouse.modifiers.rawValue,
                    x: mouse.xPixels,
                    y: mouse.yPixels,
                    columns: geometry.columns,
                    rows: geometry.rows,
                    cellWidth: geometry.cellWidth,
                    cellHeight: geometry.cellHeight,
                    padding: geometry.padding,
                    anyButtonPressed: mouse.anyButtonPressed,
                    clickCount: mouse.clickCount
                ) else {
                    throw TerminalBackendClientError.rendererNotReady
                }
                _ = try await sendLeasedTerminalInput(
                    requestID: requestID,
                    input: .mouse(cellEvent),
                    binding: binding,
                    connection: connection,
                    attemptID: inputConnectionAttemptID
                )
            }
            if mouse.action == .release {
                outcome.install(
                    try await connection.session.terminalState(surfaceID: binding.surfaceID).state
                )
            }
        case .preedit(let preedit):
            guard let presentation else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            if let receipt = rendererPresentations[presentation.presentationID]?.receipt {
                try await connection.session.setTerminalPreedit(
                    presentationID: receipt.presentationID,
                    rendererGeneration: receipt.rendererGeneration,
                    preedit: preedit.map {
                        BackendTerminalPreedit(
                            text: $0.text,
                            selectionStartUTF16: $0.selectionStartUTF16,
                            selectionLengthUTF16: $0.selectionLengthUTF16,
                            caretUTF16: $0.caretUTF16
                        )
                    }
                )
            }
        case .focus(let focused):
            if let presentation,
               rendererPresentations[presentation.presentationID] != nil,
               presentation.visible {
                let renderer = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
                outcome.rendererAttachment = renderer.attachment
                outcome.rendererActivation = renderer.activation
                if focused {
                    try await markLatestTerminalActivitySeen(
                        binding: binding,
                        connection: connection
                    )
                }
            }
            outcome.processMetadata = try await processMetadata(
                for: binding,
                connection: connection
            )
        case .visibility(let visible):
            guard let presentation else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            if visible {
                let renderer = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
                outcome.rendererAttachment = renderer.attachment
                outcome.rendererActivation = renderer.activation
            } else {
                try await removeRendererPresentation(
                    presentationID: presentation.presentationID,
                    connection: connection
                )
            }
            outcome.processMetadata = try await processMetadata(
                for: binding,
                connection: connection
            )
        case .resize(let viewport):
            let controlProtocol = try await connection.session.terminalControlProtocol()
            if let presentation, presentation.visible {
                let renderer = try await configureRenderer(
                    presentation,
                    binding: binding,
                    connection: connection
                )
                outcome.rendererAttachment = renderer.attachment
                outcome.rendererActivation = renderer.activation
                if controlProtocol == .leasedV9,
                   let columns = viewport.proposedColumns.flatMap(UInt16.init(exactly:)),
                   let rows = viewport.proposedRows.flatMap(UInt16.init(exactly:)) {
                    _ = try await sendLeasedTerminalGeometry(
                        requestID: requestID,
                        columns: columns,
                        rows: rows,
                        presentation: presentation,
                        binding: binding,
                        connection: connection
                    )
                }
            } else if controlProtocol == .legacyV8,
                      let columns = viewport.proposedColumns.flatMap(UInt16.init(exactly:)),
                      let rows = viewport.proposedRows.flatMap(UInt16.init(exactly:)) {
                _ = try await connection.session.resizeTerminal(
                    surface: binding.surfaceHandle,
                    columns: columns,
                    rows: rows
                )
            }
        case .bindingAction(let action, let repeatCount):
            let response = try await connection.session.performTerminalBindingAction(
                surfaceID: binding.surfaceID,
                action: action,
                repeatCount: repeatCount
            )
            outcome.install(response)
        case .selection(let operation):
            let response = try await connection.session.terminalSelection(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation
            )
            outcome.install(response.state)
            outcome.selection = response.selection?.externalSelection
            outcome.selectionWasRead = true
        case .copyMode(let operation, let adjustment, let count):
            let response = try await connection.session.terminalCopyMode(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                adjustment: adjustment?.backendAdjustment,
                count: count
            )
            outcome.install(response)
        case .search(let operation, let query):
            let response = try await connection.session.terminalSearch(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                query: query
            )
            outcome.install(response)
        case .scroll(let operation, let amount):
            let response = try await connection.session.terminalScroll(
                surfaceID: binding.surfaceID,
                operation: operation.backendOperation,
                amount: amount
            )
            outcome.install(response)
        case .reparent(let workspaceID):
            if let presentation {
                try await removeRendererPresentation(
                    presentationID: presentation.presentationID,
                    connection: connection
                )
            }
            let placement = try await connection.session.reparentTerminal(
                surfaceID: binding.surfaceID,
                workspaceID: WorkspaceID(rawValue: workspaceID)
            )
            guard placement.workspaceID.rawValue == workspaceID,
                  placement.surfaceID == binding.surfaceID,
                  placement.surface == binding.surfaceHandle else {
                await invalidate(connection)
                throw BackendProtocolError.peerIdentityMismatch
            }
            let updatedBinding = TerminalBackendTerminalBinding(
                authority: binding.authority,
                appWorkspaceID: workspaceID,
                appSurfaceID: binding.appSurfaceID,
                workspaceHandle: placement.workspace,
                workspaceID: placement.workspaceID,
                surfaceHandle: placement.surface,
                surfaceID: placement.surfaceID,
                columns: binding.columns,
                rows: binding.rows,
                created: false
            )
            outcome.binding = updatedBinding
            if let presentation, presentation.visible {
                let renderer = try await configureRenderer(
                    presentation,
                    binding: updatedBinding,
                    connection: connection
                )
                outcome.rendererAttachment = renderer.attachment
                outcome.rendererActivation = renderer.activation
            }
        case .closeCanonicalTerminal:
            let presentationIDs = rendererPresentations.compactMap { identifier, record in
                record.binding.appSurfaceID == binding.appSurfaceID ? identifier : nil
            }
            for presentationID in presentationIDs {
                try await removeRendererPresentation(
                    presentationID: presentationID,
                    connection: connection
                )
            }
            try await connection.session.closeTerminal(surface: binding.surfaceHandle)
            outcome.lifecycle = .processExited
        }
        return outcome
    }

    private func markLatestTerminalActivitySeen(
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws {
        guard let snapshot = await connection.session.currentTerminalActivitySnapshot(),
              let fact = snapshot.facts.first(where: {
                  $0.surfaceID == binding.surfaceID
              }),
              snapshot.isUnread(surfaceID: binding.surfaceID) else {
            return
        }
        let receipt = try await connection.session.markTerminalSeen(
            surfaceID: binding.surfaceID,
            activitySequence: fact.sequence
        )
        guard receipt.readerUUID == snapshot.readerUUID,
              receipt.surfaceID == binding.surfaceID,
              receipt.seenSequence == fact.sequence else {
            await invalidate(connection)
            throw BackendProtocolError.peerIdentityMismatch
        }
    }

    func readScreenText(
        _ request: TerminalExternalScreenTextRequest,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String? {
        let connection = try await connectedSession(for: binding)
        let text = try await connection.session.readTerminalScreen(
            surface: binding.surfaceHandle
        ).text
        switch request {
        case .visible:
            return text
        case .vtTail(let maximumRows, let maximumBytes):
            return screenTextLimiter.tail(
                text,
                maximumRows: maximumRows,
                maximumBytes: maximumBytes
            )
        }
    }

    func readSelection(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalSelection? {
        let connection = try await connectedSession(for: binding)
        return try await connection.session.terminalSelection(
            surfaceID: binding.surfaceID,
            operation: .read
        ).selection?.externalSelection
    }

    func readTerminalUXState(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendMutationOutcome {
        let connection = try await connectedSession(for: binding)
        var outcome = TerminalBackendMutationOutcome()
        outcome.install(
            try await connection.session.terminalState(surfaceID: binding.surfaceID).state
        )
        return outcome
    }

    func readAccessibilitySnapshot(
        presentationID: UUID,
        expectedContentSequence: UInt64,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalAccessibilitySnapshot {
        let connection = try await connectedSession(for: binding)
        guard let record = rendererPresentations[presentationID],
              record.binding.appSurfaceID == binding.appSurfaceID else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let backend = try await connection.session.terminalAccessibilitySnapshot(
            presentationID: record.backendID,
            expectedGeneration: record.canonicalGeneration,
            expectedContentSequence: expectedContentSequence
        )
        guard backend.surfaceID == binding.surfaceID,
              backend.presentationID == record.backendID,
              backend.presentationGeneration == record.canonicalGeneration,
              backend.contentSequence == expectedContentSequence else {
            await invalidate(connection)
            throw BackendProtocolError.peerIdentityMismatch
        }
        do {
            return try backend.externalSnapshot(
                appSurfaceID: binding.appSurfaceID,
                appPresentationID: presentationID
            )
        } catch {
            await invalidate(connection)
            throw error
        }
    }

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String {
        let connection = try await connectedSession(for: binding)
        guard snapshot.surfaceID == binding.appSurfaceID,
              let record = rendererPresentations[snapshot.presentationID],
              record.binding.appSurfaceID == binding.appSurfaceID,
              snapshot.presentationID == record.descriptor.presentationID else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        return try await connection.session.activateTerminalAccessibilityLink(
            presentationID: record.backendID,
            expectedGeneration: record.canonicalGeneration,
            terminalRevision: snapshot.terminalRevision,
            contentRevision: snapshot.contentRevision,
            viewportRevision: snapshot.viewportRevision,
            linkID: link.id
        ).target
    }

    func activateHyperlink(
        at event: TerminalExternalMouseEvent,
        contentSequence: UInt64,
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalHyperlinkHit {
        let connection = try await connectedSession(for: binding)
        guard event.action == .release,
              let record = rendererPresentations[presentationID],
              record.binding.appSurfaceID == binding.appSurfaceID,
              let geometry = rendererGeometry(record),
              let cell = BackendTerminalCellMouseEvent(
                action: event.action.backendAction,
                button: event.button?.backendButton,
                modifiers: event.modifiers.rawValue,
                x: event.xPixels,
                y: event.yPixels,
                columns: geometry.columns,
                rows: geometry.rows,
                cellWidth: geometry.cellWidth,
                cellHeight: geometry.cellHeight,
                padding: geometry.padding,
                anyButtonPressed: event.anyButtonPressed,
                clickCount: event.clickCount
              ) else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        let hit = try await connection.session.terminalHyperlinkAtCell(
            presentationID: record.backendID,
            expectedGeneration: record.canonicalGeneration,
            expectedContentSequence: contentSequence,
            column: cell.column,
            row: cell.row
        )
        guard hit.surfaceID == binding.surfaceID,
              hit.presentationID == record.backendID,
              hit.presentationGeneration == record.canonicalGeneration,
              hit.contentSequence == contentSequence else {
            await invalidate(connection)
            throw BackendProtocolError.peerIdentityMismatch
        }
        return TerminalExternalHyperlinkHit(
            target: hit.target,
            contentSequence: hit.contentSequence,
            presentationGeneration: hit.presentationGeneration,
            column: hit.column,
            row: hit.row
        )
    }

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async throws {
        rendererRemovalRequests.insert(presentationID)
        if var record = rendererPresentations[presentationID] {
            guard binding == nil || binding?.appSurfaceID == record.binding.appSurfaceID else {
                rendererRemovalRequests.remove(presentationID)
                return
            }
            record.removalPending = true
            rendererPresentations[presentationID] = record
        }
        let connection = try await connectedSession()
        try await removeRendererPresentation(
            presentationID: presentationID,
            connection: connection,
            expectedAppSurfaceID: binding?.appSurfaceID
        )
    }

    func activateRenderer(_ activation: TerminalBackendRendererActivation) async throws {
        guard let record = rendererPresentations[activation.presentationID],
              !record.removalPending,
              let receipt = record.receipt,
              let workerIdentity = record.workerIdentity,
              let workerEffectiveUserID = receipt.workerEffectiveUserID,
              receipt.workerState == .ready,
              activation.fence.daemonInstanceID == receipt.daemonInstanceID.rawValue,
              activation.fence.rendererEpoch == receipt.rendererEpoch,
              activation.fence.presentationID == receipt.presentationID.rawValue,
              activation.fence.presentationGeneration == receipt.rendererGeneration,
              activation.worker.processID == workerIdentity.processID,
              activation.worker.effectiveUserID == workerEffectiveUserID,
              activation.worker.processInstanceToken.startTimeSeconds
                == workerIdentity.processInstanceToken.startTimeSeconds,
              activation.worker.processInstanceToken.startTimeMicroseconds
                == workerIdentity.processInstanceToken.startTimeMicroseconds,
              let workerProcessID = UInt32(exactly: workerIdentity.processID) else {
            throw TerminalBackendClientError.rendererNotReady
        }
        try validateRendererWorkerForActivation(workerIdentity)
        let connection = try await connectedSession()
        guard connection.readiness.authority.daemonInstanceID == receipt.daemonInstanceID else {
            throw TerminalBackendClientError.rendererNotReady
        }
        try await connection.session.activateRendererPresentation(
            id: record.backendID,
            expectedGeneration: record.canonicalGeneration,
            rendererGeneration: receipt.rendererGeneration,
            rendererEpoch: receipt.rendererEpoch,
            workerProcessID: workerProcessID,
            workerProcessInstanceToken: workerIdentity.processInstanceToken
        )
    }

    func releaseFrame(_ release: TerminalRenderFrameRelease) async throws {
        let connection = try await connectedSession()
        guard connection.readiness.authority.daemonInstanceID.rawValue
                == release.metadata.daemonInstanceID else {
            let identity = try rendererWorkerIdentity(
                daemonInstanceID: release.metadata.daemonInstanceID,
                rendererEpoch: release.metadata.rendererEpoch,
                processID: UInt32(exactly: release.workerIdentity.processID),
                processInstanceToken: BackendRendererProcessInstanceToken(
                    startTimeSeconds: release.workerIdentity
                        .processInstanceToken.startTimeSeconds,
                    startTimeMicroseconds: release.workerIdentity
                        .processInstanceToken.startTimeMicroseconds
                )
            )
            try await awaitRendererWorkerExit(identity)
            return
        }
        _ = try await connection.session.releaseRendererFrame(
            BackendRendererFrameRelease(
                daemonInstanceID: DaemonInstanceID(
                    rawValue: release.metadata.daemonInstanceID
                ),
                rendererEpoch: release.metadata.rendererEpoch,
                terminalID: SurfaceID(rawValue: release.metadata.terminalID),
                terminalEpoch: release.metadata.terminalEpoch,
                terminalSequence: release.metadata.terminalSequence,
                presentationID: PresentationID(
                    rawValue: release.metadata.presentationID
                ),
                presentationGeneration: release.metadata.presentationGeneration,
                frameSequence: release.metadata.frameSequence,
                surfaceID: release.surfaceID
            )
        )
    }

    private func configureRenderer(
        _ descriptor: TerminalBackendPresentationDescriptor,
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> RendererConfigurationResult {
        guard !rendererRemovalRequests.contains(descriptor.presentationID) else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        await acquireRendererPresentationOperation(descriptor.presentationID)
        defer { releaseRendererPresentationOperation(descriptor.presentationID) }
        guard !rendererRemovalRequests.contains(descriptor.presentationID) else {
            throw TerminalBackendClientError.presentationUnavailable
        }
        guard descriptor.visible,
              descriptor.viewport.widthPixels > 0,
              descriptor.viewport.heightPixels > 0,
              let width = UInt32(exactly: descriptor.viewport.widthPixels),
              let height = UInt32(exactly: descriptor.viewport.heightPixels) else {
            throw TerminalBackendClientError.presentationUnavailable
        }

        var record: RendererPresentationRecord
        let openedNewPresentation: Bool
        if let existing = rendererPresentations[descriptor.presentationID],
           existing.binding.authority == binding.authority {
            guard existing.binding.appSurfaceID == binding.appSurfaceID else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            guard !existing.removalPending else {
                throw TerminalBackendClientError.presentationUnavailable
            }
            record = existing
            openedNewPresentation = false
        } else {
            if let existing = rendererPresentations[descriptor.presentationID] {
                try await awaitRendererWorkerExit(for: existing)
                removeRendererPresentationRecordIfCurrent(
                    presentationID: descriptor.presentationID,
                    record: existing
                )
            }
            let opened = try await connection.session.openPresentation(
                view: BackendPresentationView(
                    workspaceID: binding.workspaceID,
                    surfaceID: binding.surfaceID
                ),
                zoom: BackendPresentationZoom(),
                scroll: BackendPresentationScroll(surfaceID: binding.surfaceID)
            )
            record = RendererPresentationRecord(
                binding: binding,
                backendID: opened.id,
                canonicalGeneration: opened.generation,
                descriptor: descriptor,
                receipt: nil,
                ready: nil,
                workerIdentity: nil,
                removalPending: false
            )
            openedNewPresentation = true
        }

        let columns = descriptor.viewport.proposedColumns.flatMap(UInt16.init(exactly:))
            ?? record.ready?.columns
            ?? record.receipt?.metrics?.columns
            ?? record.receipt?.columns
            ?? binding.columns
        let rows = descriptor.viewport.proposedRows.flatMap(UInt16.init(exactly:))
            ?? record.ready?.rows
            ?? record.receipt?.metrics?.rows
            ?? record.receipt?.rows
            ?? binding.rows
        let receipt: BackendRendererPresentationReceipt
        do {
            receipt = try await connection.session.configureRendererPresentation(
                id: record.backendID,
                expectedGeneration: record.canonicalGeneration,
                configuration: BackendRendererPresentationConfiguration(
                    width: width,
                    height: height,
                    backingScaleFactor: descriptor.viewport.xScale,
                    columns: columns,
                    rows: rows,
                    pixelFormat: descriptor.pixelFormat.backendPixelFormat,
                    colorSpace: descriptor.colorSpace.backendColorSpace,
                    frameEndpointService: descriptor.endpoint.serviceName,
                    frameEndpointCapability: descriptor.endpoint.capability,
                    resolvedConfigRevision: descriptor.resolvedConfigRevision,
                    resolvedConfig: descriptor.resolvedConfig,
                    focused: descriptor.focused,
                    cursorBlinkVisible: descriptor.focused && descriptor.visible,
                    preedit: descriptor.preedit?.text,
                    preeditSelectionStartUTF16: descriptor.preedit?.selectionStartUTF16 ?? 0,
                    preeditSelectionLengthUTF16: descriptor.preedit?.selectionLengthUTF16 ?? 0,
                    preeditCaretUTF16: descriptor.preedit?.caretUTF16 ?? 0
                )
            )
        } catch {
            if openedNewPresentation {
                try? await connection.session.closePresentation(id: record.backendID)
            }
            throw error
        }
        let workerIdentity: TerminalBackendRendererWorkerProcessIdentity?
        do {
            workerIdentity = try registerRendererWorker(
                daemonInstanceID: receipt.daemonInstanceID.rawValue,
                rendererEpoch: receipt.rendererEpoch,
                processID: receipt.workerProcessID,
                processInstanceToken: receipt.workerProcessInstanceToken
            )
        } catch {
            if openedNewPresentation {
                try? await connection.session.closePresentation(id: record.backendID)
            }
            throw error
        }
        record.canonicalGeneration = receipt.canonicalGeneration
        record.descriptor = descriptor
        record.receipt = receipt
        record.ready = nil
        record.workerIdentity = workerIdentity
        record.removalPending = rendererRemovalRequests.contains(descriptor.presentationID)
        rendererPresentations[descriptor.presentationID] = record
        guard !record.removalPending else {
            return RendererConfigurationResult(attachment: nil, activation: nil)
        }
        return try RendererConfigurationResult(
            attachment: rendererAttachment(record),
            activation: rendererActivation(record)
        )
    }

    private func removeRendererPresentation(
        presentationID: UUID,
        connection: TerminalBackendConnectedSession,
        expectedAppSurfaceID: UUID? = nil
    ) async throws {
        rendererRemovalRequests.insert(presentationID)
        await acquireRendererPresentationOperation(presentationID)
        defer { releaseRendererPresentationOperation(presentationID) }
        guard var record = rendererPresentations[presentationID] else {
            rendererRemovalRequests.remove(presentationID)
            return
        }
        if let expectedAppSurfaceID,
           expectedAppSurfaceID != record.binding.appSurfaceID {
            rendererRemovalRequests.remove(presentationID)
            return
        }
        guard connection.readiness.authority.daemonInstanceID
                == record.binding.authority.daemonInstanceID else {
            try await awaitRendererWorkerExit(for: record)
            removeRendererPresentationRecordIfCurrent(
                presentationID: presentationID,
                record: record
            )
            rendererRemovalRequests.remove(presentationID)
            return
        }
        guard connection.readiness.authority == record.binding.authority else {
            throw TerminalBackendClientError.authorityChanged(
                expected: record.binding.authority,
                actual: connection.readiness.authority
            )
        }
        // Actor methods are reentrant at every daemon RPC. Publish the
        // tombstone before the first await so neither another mutation nor a
        // readiness event can resurrect this presentation while removal is in
        // flight.
        record.removalPending = true
        rendererPresentations[presentationID] = record
        if (try? await connection.session.terminalControlProtocol()) == .leasedV9 {
            // Renderer presentations own geometry only. Input stays on the
            // surface's non-rendering stable owner across workspace switches.
            try? await connection.session.releaseTerminalLease(
                kind: .geometry,
                surfaceID: record.binding.surfaceID,
                presentationID: record.backendID,
                presentationGeneration: record.canonicalGeneration
            )
        }
        // Detach even after a worker-death event cleared the frame receipt.
        // The daemon still owns the canonical presentation runtime and must
        // mark it removal-pending so a replacement worker cannot rehydrate it.
        try await connection.session.detachRendererPresentation(
            id: record.backendID,
            expectedGeneration: record.canonicalGeneration
        )
        removeRendererPresentationRecordIfCurrent(
            presentationID: presentationID,
            record: record
        )
        rendererRemovalRequests.remove(presentationID)
        try? await connection.session.closePresentation(id: record.backendID)
    }

    private func acquireRendererPresentationOperation(_ presentationID: UUID) async {
        if activeRendererPresentationOperations.insert(presentationID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            rendererPresentationOperationWaiters[presentationID, default: []]
                .append(continuation)
        }
    }

    private func releaseRendererPresentationOperation(_ presentationID: UUID) {
        if var waiters = rendererPresentationOperationWaiters[presentationID],
           !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                rendererPresentationOperationWaiters.removeValue(forKey: presentationID)
            } else {
                rendererPresentationOperationWaiters[presentationID] = waiters
            }
            next.resume()
            return
        }
        activeRendererPresentationOperations.remove(presentationID)
    }

    private func registerRendererWorker(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        processID: UInt32?,
        processInstanceToken: BackendRendererProcessInstanceToken?
    ) throws -> TerminalBackendRendererWorkerProcessIdentity? {
        guard let processID else {
            guard processInstanceToken == nil else {
                throw BackendProtocolError.malformedMessage
            }
            return nil
        }
        guard let processInstanceToken else {
            throw BackendProtocolError.malformedMessage
        }
        let identity = try rendererWorkerIdentity(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            processID: processID,
            processInstanceToken: processInstanceToken
        )
        switch rendererWorkerExitLedger.register(identity) {
        case .installed:
            guard let exitFence = rendererWorkerExitLedger.fence(for: identity.epoch) else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            let registration = rendererWorkerExitMonitor.register(identity) {
                [weak self, exitFence] exited in
                // Settle the process-shared fence synchronously. The actor callback
                // may not run until after configure returns, but no activation may
                // escape once NOTE_EXIT has fired.
                exitFence.finish()
                Task { await self?.rendererWorkerDidExit(exited) }
            }
            switch registration {
            case .watching:
                guard !exitFence.isFinished else {
                    rendererWorkerDidExit(identity)
                    return nil
                }
            case .alreadyExited:
                exitFence.finish()
                rendererWorkerDidExit(identity)
                return nil
            case .unverifiable:
                rendererWorkerExitLedger.remove(identity)
                throw BackendProtocolError.peerIdentityMismatch
            }
        case .existing:
            guard rendererWorkerIsLive(identity) else { return nil }
        case .conflict:
            throw BackendProtocolError.peerIdentityMismatch
        }
        return rendererWorkerIsLive(identity) ? identity : nil
    }

    private func registerRendererWorkers(
        _ response: BackendRendererWorkersResponse,
        for connection: TerminalBackendConnectedSession
    ) throws {
        guard response.daemonInstanceID == connection.readiness.authority.daemonInstanceID else {
            throw BackendProtocolError.peerIdentityMismatch
        }
        for worker in response.workers {
            _ = try registerRendererWorker(
                daemonInstanceID: response.daemonInstanceID.rawValue,
                rendererEpoch: worker.rendererEpoch,
                processID: worker.processID,
                processInstanceToken: worker.processInstanceToken
            )
        }
    }

    private func rendererWorkerIdentity(
        daemonInstanceID: UUID,
        rendererEpoch: UInt64,
        processID: UInt32?,
        processInstanceToken: BackendRendererProcessInstanceToken
    ) throws -> TerminalBackendRendererWorkerProcessIdentity {
        guard let processID,
              rendererEpoch > 0 else {
            throw BackendProtocolError.malformedMessage
        }
        guard let signedProcessID = pid_t(exactly: processID), signedProcessID > 0 else {
            throw BackendProtocolError.malformedMessage
        }
        return TerminalBackendRendererWorkerProcessIdentity(
            epoch: TerminalBackendRendererWorkerEpoch(
                daemonInstanceID: daemonInstanceID,
                rendererEpoch: rendererEpoch
            ),
            processID: signedProcessID,
            processInstanceToken: processInstanceToken
        )
    }

    private func awaitRendererWorkerExit(
        for record: RendererPresentationRecord
    ) async throws {
        if let workerIdentity = record.workerIdentity {
            try await awaitRendererWorkerExit(workerIdentity)
            return
        }
        guard let receipt = record.receipt else { return }
        // Backoff has no live child. Starting and Ready must carry a PID so
        // daemon replacement cannot turn an unknown process into false proof.
        guard receipt.workerState == .backoff else {
            throw TerminalBackendClientError.rendererNotReady
        }
    }

    private func awaitRendererWorkerExit(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) async throws {
        if rendererWorkerExitLedger.identity(for: identity.epoch) == nil {
            _ = try registerRendererWorker(
                daemonInstanceID: identity.epoch.daemonInstanceID,
                rendererEpoch: identity.epoch.rendererEpoch,
                processID: UInt32(exactly: identity.processID),
                processInstanceToken: identity.processInstanceToken
            )
        }
        guard rendererWorkerExitLedger.identity(for: identity.epoch) == identity,
              let exited = rendererWorkerExitLedger.hasExited(identity.epoch),
              let fence = rendererWorkerExitLedger.fence(for: identity.epoch) else {
            throw BackendProtocolError.peerIdentityMismatch
        }
        guard !exited else { return }
        await fence.completion.value
    }

    private func rendererWorkerDidExit(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) {
        _ = rendererWorkerExitLedger.markExited(identity)
    }

    private func rendererWorkerIsLive(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) -> Bool {
        rendererWorkerExitLedger.identity(for: identity.epoch) == identity
            && rendererWorkerExitLedger.hasExited(identity.epoch) == false
            && rendererWorkerExitLedger.fence(for: identity.epoch)?.isFinished == false
    }

    private func validateRendererWorkerForActivation(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) throws {
        guard rendererWorkerIsLive(identity) else {
            throw TerminalBackendClientError.rendererNotReady
        }
    }

    var debugRendererWorkerExitWaiterCount: Int {
        rendererWorkerExitLedger.activeFenceCount
    }

    func debugRegisterRendererWorker(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) throws -> Bool {
        try registerRendererWorker(
            daemonInstanceID: identity.epoch.daemonInstanceID,
            rendererEpoch: identity.epoch.rendererEpoch,
            processID: UInt32(exactly: identity.processID),
            processInstanceToken: identity.processInstanceToken
        ) != nil
    }

    func debugRendererWorkerCanActivate(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) -> Bool {
        rendererWorkerIsLive(identity)
    }

    func debugValidateRendererWorkerForActivation(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) throws {
        try validateRendererWorkerForActivation(identity)
    }

    func debugAwaitRendererWorkerExit(
        _ identity: TerminalBackendRendererWorkerProcessIdentity
    ) async throws {
        try await awaitRendererWorkerExit(identity)
    }

    private func removeRendererPresentationRecordIfCurrent(
        presentationID: UUID,
        record: RendererPresentationRecord
    ) {
        guard let current = rendererPresentations[presentationID],
              current.backendID == record.backendID,
              current.canonicalGeneration == record.canonicalGeneration else { return }
        rendererPresentations.removeValue(forKey: presentationID)
    }

    private func rendererAttachment(
        _ record: RendererPresentationRecord
    ) throws -> TerminalBackendRendererAttachment? {
        guard let receipt = record.receipt else { return nil }
        let processID: UInt32
        let effectiveUserID: UInt32
        let metrics: (
            columns: UInt16,
            rows: UInt16,
            cellWidth: UInt32,
            cellHeight: UInt32,
            padding: BackendRendererPadding
        )
        if let ready = record.ready {
            processID = ready.workerProcessID
            effectiveUserID = ready.workerEffectiveUserID
            metrics = (
                ready.columns,
                ready.rows,
                ready.cellWidth,
                ready.cellHeight,
                ready.padding
            )
        } else if let receiptMetrics = receipt.metrics,
                  let receiptProcessID = receipt.workerProcessID,
                  let receiptEffectiveUserID = receipt.workerEffectiveUserID {
            processID = receiptProcessID
            effectiveUserID = receiptEffectiveUserID
            metrics = (
                receiptMetrics.columns,
                receiptMetrics.rows,
                receiptMetrics.cellWidth,
                receiptMetrics.cellHeight,
                receiptMetrics.padding
            )
        } else {
            return nil
        }
        guard let signedProcessID = Int32(exactly: processID),
              let workerIdentity = record.workerIdentity,
              workerIdentity.processID == signedProcessID,
              rendererWorkerIsLive(workerIdentity) else {
            throw TerminalBackendClientError.rendererNotReady
        }
        let worker = try TerminalRenderWorkerIdentity(
            processID: signedProcessID,
            effectiveUserID: effectiveUserID,
            processInstanceToken: TerminalRenderProcessInstanceToken(
                startTimeSeconds: workerIdentity.processInstanceToken.startTimeSeconds,
                startTimeMicroseconds: workerIdentity.processInstanceToken.startTimeMicroseconds
            )
        )
        let fence = try TerminalRenderPresentationFence(
            daemonInstanceID: receipt.daemonInstanceID.rawValue,
            rendererEpoch: receipt.rendererEpoch,
            terminalID: receipt.terminalID.rawValue,
            terminalEpoch: receipt.terminalEpoch,
            minimumTerminalSequence: max(
                receipt.minimumContentSequence,
                record.ready?.canonicalSequence ?? 0
            ),
            presentationID: receipt.presentationID.rawValue,
            presentationGeneration: receipt.rendererGeneration,
            width: receipt.width,
            height: receipt.height,
            pixelFormat: receipt.pixelFormat.terminalPixelFormat,
            colorSpace: receipt.colorSpace.terminalColorSpace,
            completionRequirement: .producerCompleted
        )
        return TerminalBackendRendererAttachment(
            fence: fence,
            worker: worker,
            cellMetrics: TerminalExternalCellMetrics(
                columns: Int(metrics.columns),
                rows: Int(metrics.rows),
                cellWidthPixels: Int(metrics.cellWidth),
                cellHeightPixels: Int(metrics.cellHeight),
                surfaceWidthPixels: Int(receipt.width),
                surfaceHeightPixels: Int(receipt.height),
                backingScale: receipt.backingScaleFactor
            )
        )
    }

    private func rendererActivation(
        _ record: RendererPresentationRecord
    ) throws -> TerminalBackendRendererActivation? {
        guard let receipt = record.receipt,
              receipt.workerState == .ready,
              let processID = receipt.workerProcessID,
              let effectiveUserID = receipt.workerEffectiveUserID,
              let signedProcessID = Int32(exactly: processID),
              let workerIdentity = record.workerIdentity,
              workerIdentity.processID == signedProcessID,
              rendererWorkerIsLive(workerIdentity) else { return nil }
        let worker = try TerminalRenderWorkerIdentity(
            processID: signedProcessID,
            effectiveUserID: effectiveUserID,
            processInstanceToken: TerminalRenderProcessInstanceToken(
                startTimeSeconds: workerIdentity.processInstanceToken.startTimeSeconds,
                startTimeMicroseconds: workerIdentity.processInstanceToken.startTimeMicroseconds
            )
        )
        let fence = try TerminalRenderPresentationFence(
            daemonInstanceID: receipt.daemonInstanceID.rawValue,
            rendererEpoch: receipt.rendererEpoch,
            terminalID: receipt.terminalID.rawValue,
            terminalEpoch: receipt.terminalEpoch,
            minimumTerminalSequence: receipt.minimumContentSequence,
            presentationID: receipt.presentationID.rawValue,
            presentationGeneration: receipt.rendererGeneration,
            width: receipt.width,
            height: receipt.height,
            pixelFormat: receipt.pixelFormat.terminalPixelFormat,
            colorSpace: receipt.colorSpace.terminalColorSpace,
            completionRequirement: .producerCompleted
        )
        return TerminalBackendRendererActivation(
            presentationID: record.descriptor.presentationID,
            fence: fence,
            worker: worker
        )
    }

    private func rendererGeometry(
        _ record: RendererPresentationRecord
    ) -> (
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32,
        padding: BackendRendererPadding
    )? {
        if let ready = record.ready {
            return (
                ready.columns,
                ready.rows,
                ready.cellWidth,
                ready.cellHeight,
                ready.padding
            )
        }
        guard let metrics = record.receipt?.metrics else { return nil }
        return (
            metrics.columns,
            metrics.rows,
            metrics.cellWidth,
            metrics.cellHeight,
            metrics.padding
        )
    }

    private func stableTerminalInputOwner(
        surfaceID: SurfaceID,
        binding: TerminalBackendTerminalBinding?,
        connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async throws -> TerminalInputOwnerRecord {
        try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
        var location = try terminalInputLocation(
            surfaceID: surfaceID,
            binding: binding,
            connection: connection
        )

        if var existing = terminalInputOwners[surfaceID],
           existing.connectionAttemptID == attemptID,
           existing.authority == connection.readiness.authority,
           existing.location == location {
            let lease = try await connection.session.acquireTerminalLease(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: existing.presentationID,
                presentationGeneration: existing.presentationGeneration,
                ttlMilliseconds: Self.terminalInputOwnerTTLMilliseconds
            )
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            location = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: binding,
                connection: connection
            )
            guard location == existing.location,
                  terminalInputOwners[surfaceID] == existing else {
                throw BackendTerminalControlError.staleLease
            }
            try validateTerminalInputLease(lease, owner: existing)
            guard lease.leaseGeneration >= existing.inputLeaseGeneration else {
                throw BackendProtocolError.peerIdentityMismatch
            }
            if lease.leaseGeneration != existing.inputLeaseGeneration {
                // A new owner-lease generation revokes every old delegation
                // in cmuxd. Mirror that revocation before publishing it.
                terminalCompatibilityGrants.removeValue(forKey: surfaceID)
                existing.inputLeaseGeneration = lease.leaseGeneration
                terminalInputOwners[surfaceID] = existing
            }
            return existing
        }

        if let existing = terminalInputOwners[surfaceID] {
            try await retireTerminalInputOwner(
                existing,
                connection: connection,
                requireRemoteRevocation: existing.connectionAttemptID == attemptID
                    && existing.authority == connection.readiness.authority
            )
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            location = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: binding,
                connection: connection
            )
        }

        var opened: BackendPresentation?
        var acquiredLease = false
        do {
            let presentation = try await connection.session.openPresentation(
                view: location.presentationView,
                zoom: BackendPresentationZoom(),
                scroll: BackendPresentationScroll(surfaceID: surfaceID)
            )
            opened = presentation
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            let currentLocation = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: binding,
                connection: connection
            )
            guard currentLocation == location,
                  presentation.generation > 0,
                  presentation.view == location.presentationView else {
                throw BackendProtocolError.peerIdentityMismatch
            }

            let activation = try await connection.session.activateTerminalPresentation(
                id: presentation.id,
                expectedGeneration: presentation.generation
            )
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            let activatedLocation = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: binding,
                connection: connection
            )
            guard activation.presentationID == presentation.id,
                  activation.presentationGeneration == presentation.generation,
                  activation.surfaceID == surfaceID,
                  activatedLocation == location else {
                throw BackendProtocolError.peerIdentityMismatch
            }

            let lease = try await connection.session.acquireTerminalLease(
                kind: .input,
                surfaceID: surfaceID,
                presentationID: presentation.id,
                presentationGeneration: presentation.generation,
                ttlMilliseconds: Self.terminalInputOwnerTTLMilliseconds
            )
            acquiredLease = true
            try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            let leasedLocation = try terminalInputLocation(
                surfaceID: surfaceID,
                binding: binding,
                connection: connection
            )
            guard leasedLocation == location else {
                throw BackendTerminalControlError.staleLease
            }
            let owner = TerminalInputOwnerRecord(
                connectionAttemptID: attemptID,
                authority: connection.readiness.authority,
                location: location,
                presentationID: presentation.id,
                presentationGeneration: presentation.generation,
                inputLeaseGeneration: lease.leaseGeneration
            )
            try validateTerminalInputLease(lease, owner: owner)
            guard terminalInputOwners[surfaceID] == nil else {
                throw BackendTerminalControlError.staleLease
            }
            terminalInputOwners[surfaceID] = owner
            return owner
        } catch {
            if let opened {
                if acquiredLease {
                    try? await connection.session.releaseTerminalLease(
                        kind: .input,
                        surfaceID: surfaceID,
                        presentationID: opened.id,
                        presentationGeneration: opened.generation
                    )
                }
                try? await connection.session.closePresentation(id: opened.id)
            }
            throw error
        }
    }

    private func validateTerminalInputLease(
        _ lease: BackendTerminalLease,
        owner: TerminalInputOwnerRecord
    ) throws {
        guard lease.kind == .input,
              lease.surfaceID == owner.location.surfaceID,
              lease.presentationID == owner.presentationID,
              lease.presentationGeneration == owner.presentationGeneration,
              lease.leaseGeneration > 0,
              lease.nextSequence > 0,
              lease.nextGlobalInputSequence != nil else {
            throw BackendProtocolError.peerIdentityMismatch
        }
    }

    private func terminalInputLocation(
        surfaceID: SurfaceID,
        binding: TerminalBackendTerminalBinding?,
        connection: TerminalBackendConnectedSession
    ) throws -> TerminalInputTopologyLocation {
        guard let snapshot = latestSnapshot,
              snapshot.authority == connection.readiness.authority else {
            throw TerminalBackendTopologyMutationError.canonicalSnapshotUnavailable
        }
        return try terminalInputLocation(
            surfaceID: surfaceID,
            binding: binding,
            snapshot: snapshot
        )
    }

    private func terminalInputLocation(
        surfaceID: SurfaceID,
        binding: TerminalBackendTerminalBinding?,
        snapshot: TopologySnapshot
    ) throws -> TerminalInputTopologyLocation {
        for workspace in snapshot.topology.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    guard let surface = pane.tabs.first(where: { $0.uuid == surfaceID }) else {
                        continue
                    }
                    guard surface.kind == "pty" else {
                        throw TerminalBackendClientError.presentationUnavailable
                    }
                    let location = TerminalInputTopologyLocation(
                        workspaceHandle: workspace.id,
                        workspaceID: workspace.uuid,
                        screenHandle: screen.id,
                        screenID: screen.uuid,
                        paneHandle: pane.id,
                        paneID: pane.uuid,
                        surfaceHandle: surface.id,
                        surfaceID: surface.uuid
                    )
                    if let binding {
                        guard binding.authority == snapshot.authority,
                              binding.workspaceHandle == location.workspaceHandle,
                              binding.workspaceID == location.workspaceID,
                              binding.surfaceHandle == location.surfaceHandle,
                              binding.surfaceID == location.surfaceID else {
                            throw BackendTerminalControlError.staleLease
                        }
                    }
                    return location
                }
            }
        }
        throw TerminalBackendTopologyMutationError.surfaceNotFound(surfaceID)
    }

    private func requireCurrentTerminalInputConnection(
        _ connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) throws {
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else {
            throw BackendProtocolError.notConnected
        }
    }

    private func acquireTerminalInputOperation(_ surfaceID: SurfaceID) async {
        if activeTerminalInputOperations.insert(surfaceID).inserted { return }
        await withCheckedContinuation { continuation in
            terminalInputOperationWaiters[surfaceID, default: []].append(continuation)
        }
    }

    private func releaseTerminalInputOperation(_ surfaceID: SurfaceID) {
        if var waiters = terminalInputOperationWaiters[surfaceID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                terminalInputOperationWaiters.removeValue(forKey: surfaceID)
            } else {
                terminalInputOperationWaiters[surfaceID] = waiters
            }
            next.resume()
        } else {
            activeTerminalInputOperations.remove(surfaceID)
        }
    }

    private func retireTerminalInputOwner(
        _ owner: TerminalInputOwnerRecord,
        connection: TerminalBackendConnectedSession,
        requireRemoteRevocation: Bool
    ) async throws {
        guard terminalInputOwners[owner.location.surfaceID] == owner else { return }
        let grants = terminalCompatibilityGrants
            .removeValue(forKey: owner.location.surfaceID)
            .map { Array($0.values) } ?? []
        terminalInputOwners.removeValue(forKey: owner.location.surfaceID)
        guard requireRemoteRevocation else { return }

        do {
            for grant in grants {
                if monotonicNowNanoseconds() < grant.localDeadlineNanoseconds {
                    try await connection.session.revokeTerminalInputDelegation(
                        surfaceID: owner.location.surfaceID,
                        presentationID: owner.presentationID,
                        presentationGeneration: owner.presentationGeneration,
                        delegation: grant.delegation
                    )
                }
            }
            try await connection.session.releaseTerminalLease(
                kind: .input,
                surfaceID: owner.location.surfaceID,
                presentationID: owner.presentationID,
                presentationGeneration: owner.presentationGeneration
            )
            try await connection.session.closePresentation(id: owner.presentationID)
        } catch {
            // Closing this exact primary connection is the fail-closed fallback:
            // cmuxd revokes its owner lease and every derived delegation.
            if connected?.readiness == connection.readiness,
               connectionAttemptID == owner.connectionAttemptID {
                await invalidate(connection)
            }
            throw error
        }
    }

    private func discardTerminalInputAuthorityState() {
        terminalInputOwners.removeAll()
        terminalCompatibilityGrants.removeAll()
    }

    private func reconcileTerminalInputOwners(
        with snapshot: TopologySnapshot,
        connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async throws {
        try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
        guard snapshot.authority == connection.readiness.authority else {
            throw BackendProtocolError.peerIdentityMismatch
        }
        for surfaceID in Array(terminalInputOwners.keys) {
            await acquireTerminalInputOperation(surfaceID)
            do {
                guard let owner = terminalInputOwners[surfaceID] else {
                    releaseTerminalInputOperation(surfaceID)
                    continue
                }
                guard owner.connectionAttemptID == attemptID,
                      owner.authority == snapshot.authority else {
                    terminalInputOwners.removeValue(forKey: surfaceID)
                    terminalCompatibilityGrants.removeValue(forKey: surfaceID)
                    releaseTerminalInputOperation(surfaceID)
                    continue
                }
                let nextLocation = try? terminalInputLocation(
                    surfaceID: surfaceID,
                    binding: nil,
                    snapshot: snapshot
                )
                if nextLocation == nil {
                    // Canonical deletion retires the PTY, presentation, lease,
                    // and delegations atomically in cmuxd before this snapshot.
                    terminalInputOwners.removeValue(forKey: surfaceID)
                    terminalCompatibilityGrants.removeValue(forKey: surfaceID)
                } else if nextLocation != owner.location {
                    try await retireTerminalInputOwner(
                        owner,
                        connection: connection,
                        requireRemoteRevocation: true
                    )
                }
                releaseTerminalInputOperation(surfaceID)
                try requireCurrentTerminalInputConnection(connection, attemptID: attemptID)
            } catch {
                releaseTerminalInputOperation(surfaceID)
                throw error
            }
        }
    }

    private func sendLeasedTerminalInput(
        requestID: UUID,
        input: BackendTerminalControlInput,
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async throws -> BackendTerminalOperationReceipt {
        await acquireTerminalInputOperation(binding.surfaceID)
        defer { releaseTerminalInputOperation(binding.surfaceID) }
        if terminalRequestsAwaitingRecovery.contains(requestID) {
            return try await recoverLeasedTerminalInput(
                requestID: requestID,
                input: input,
                binding: binding,
                startingWith: connection,
                attemptID: attemptID
            )
        }
        terminalRequestsAwaitingRecovery.insert(requestID)
        do {
            let owner = try await stableTerminalInputOwner(
                surfaceID: binding.surfaceID,
                binding: binding,
                connection: connection,
                attemptID: attemptID
            )
            let receipt = try await connection.session.sendTerminalInput(
                surfaceID: binding.surfaceID,
                presentationID: owner.presentationID,
                presentationGeneration: owner.presentationGeneration,
                requestID: requestID,
                input: input
            )
            return try await finishTerminalReceipt(
                receipt,
                expectedKind: .input,
                requestID: requestID,
                surfaceID: binding.surfaceID,
                connection: connection
            )
        } catch {
            if let terminalError = error as? BackendTerminalControlError,
               case .indeterminate = terminalError {
                return try await recoverLeasedTerminalInput(
                    requestID: requestID,
                    input: input,
                    binding: binding,
                    startingWith: connection,
                    attemptID: attemptID
                )
            }
            guard Self.shouldRetry(error) else {
                terminalRequestsAwaitingRecovery.remove(requestID)
                throw error
            }
            if connectionAttemptID == attemptID,
               connected?.readiness == connection.readiness {
                await invalidate(connection)
            }
            let replacement = try await connectedSession(for: binding)
            let replacementAttemptID = connectionAttemptID
            return try await recoverLeasedTerminalInput(
                requestID: requestID,
                input: input,
                binding: binding,
                startingWith: replacement,
                attemptID: replacementAttemptID
            )
        }
    }

    private func recoverLeasedTerminalInput(
        requestID: UUID,
        input: BackendTerminalControlInput,
        binding: TerminalBackendTerminalBinding,
        startingWith initialConnection: TerminalBackendConnectedSession,
        attemptID initialAttemptID: UUID
    ) async throws -> BackendTerminalOperationReceipt {
        var connection = initialConnection
        var attemptID = initialAttemptID
        var lastError: (any Error)?
        for attempt in 0 ..< 2 {
            do {
                let status = try await connection.session.terminalRequestStatus(
                    surfaceID: binding.surfaceID,
                    requestID: requestID
                )
                if status.status != .unknown {
                    return try await finishTerminalReceipt(
                        status,
                        expectedKind: .input,
                        requestID: requestID,
                        surfaceID: binding.surfaceID,
                        connection: connection
                    )
                }

                let owner = try await stableTerminalInputOwner(
                    surfaceID: binding.surfaceID,
                    binding: binding,
                    connection: connection,
                    attemptID: attemptID
                )
                let receipt = try await connection.session.sendTerminalInput(
                    surfaceID: binding.surfaceID,
                    presentationID: owner.presentationID,
                    presentationGeneration: owner.presentationGeneration,
                    requestID: requestID,
                    input: input
                )
                return try await finishTerminalReceipt(
                    receipt,
                    expectedKind: .input,
                    requestID: requestID,
                    surfaceID: binding.surfaceID,
                    connection: connection
                )
            } catch {
                if let terminalError = error as? BackendTerminalControlError,
                   case .indeterminate = terminalError {
                    terminalRequestsAwaitingRecovery.remove(requestID)
                    throw error
                }
                guard Self.shouldRetry(error) else {
                    terminalRequestsAwaitingRecovery.remove(requestID)
                    throw error
                }
                lastError = error
                guard attempt == 0 else { break }
                if connectionAttemptID == attemptID,
                   connected?.readiness == connection.readiness {
                    await invalidate(connection)
                }
                connection = try await connectedSession(for: binding)
                attemptID = connectionAttemptID
            }
        }
        throw lastError ?? TerminalBackendClientError.unavailable
    }

    private func sendLeasedTerminalGeometry(
        requestID: UUID,
        columns: UInt16,
        rows: UInt16,
        presentation: TerminalBackendPresentationDescriptor,
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> BackendTerminalOperationReceipt {
        if terminalRequestsAwaitingRecovery.contains(requestID) {
            return try await recoverLeasedTerminalGeometry(
                requestID: requestID,
                columns: columns,
                rows: rows,
                presentation: presentation,
                binding: binding,
                startingWith: connection
            )
        }
        terminalRequestsAwaitingRecovery.insert(requestID)
        do {
            let record = try await rendererControlRecordEnsuringConfigured(
                presentation: presentation,
                binding: binding,
                connection: connection
            )
            _ = try await connection.session.acquireTerminalLease(
                kind: .geometry,
                surfaceID: binding.surfaceID,
                presentationID: record.backendID,
                presentationGeneration: record.canonicalGeneration,
                ttlMilliseconds: 5_000
            )
            let receipt = try await connection.session.sendTerminalGeometry(
                surfaceID: binding.surfaceID,
                presentationID: record.backendID,
                presentationGeneration: record.canonicalGeneration,
                requestID: requestID,
                columns: columns,
                rows: rows
            )
            return try await finishTerminalReceipt(
                receipt,
                expectedKind: .geometry,
                requestID: requestID,
                surfaceID: binding.surfaceID,
                connection: connection
            )
        } catch {
            guard Self.shouldRetry(error) else {
                terminalRequestsAwaitingRecovery.remove(requestID)
                throw error
            }
            await invalidate(connection)
            let replacement = try await connectedSession(for: binding)
            return try await recoverLeasedTerminalGeometry(
                requestID: requestID,
                columns: columns,
                rows: rows,
                presentation: presentation,
                binding: binding,
                startingWith: replacement
            )
        }
    }

    private func recoverLeasedTerminalGeometry(
        requestID: UUID,
        columns: UInt16,
        rows: UInt16,
        presentation: TerminalBackendPresentationDescriptor,
        binding: TerminalBackendTerminalBinding,
        startingWith initialConnection: TerminalBackendConnectedSession
    ) async throws -> BackendTerminalOperationReceipt {
        var connection = initialConnection
        var lastError: (any Error)?
        for attempt in 0 ..< 2 {
            do {
                let status = try await connection.session.terminalRequestStatus(
                    surfaceID: binding.surfaceID,
                    requestID: requestID
                )
                if status.status != .unknown {
                    return try await finishTerminalReceipt(
                        status,
                        expectedKind: .geometry,
                        requestID: requestID,
                        surfaceID: binding.surfaceID,
                        connection: connection
                    )
                }

                let record = try await rendererControlRecordEnsuringConfigured(
                    presentation: presentation,
                    binding: binding,
                    connection: connection
                )
                _ = try await connection.session.acquireTerminalLease(
                    kind: .geometry,
                    surfaceID: binding.surfaceID,
                    presentationID: record.backendID,
                    presentationGeneration: record.canonicalGeneration,
                    ttlMilliseconds: 5_000
                )
                let receipt = try await connection.session.sendTerminalGeometry(
                    surfaceID: binding.surfaceID,
                    presentationID: record.backendID,
                    presentationGeneration: record.canonicalGeneration,
                    requestID: requestID,
                    columns: columns,
                    rows: rows
                )
                return try await finishTerminalReceipt(
                    receipt,
                    expectedKind: .geometry,
                    requestID: requestID,
                    surfaceID: binding.surfaceID,
                    connection: connection
                )
            } catch {
                guard Self.shouldRetry(error) else {
                    terminalRequestsAwaitingRecovery.remove(requestID)
                    throw error
                }
                lastError = error
                guard attempt == 0 else { break }
                await invalidate(connection)
                connection = try await connectedSession(for: binding)
            }
        }
        throw lastError ?? TerminalBackendClientError.unavailable
    }

    private func rendererControlRecordEnsuringConfigured(
        presentation: TerminalBackendPresentationDescriptor?,
        binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> RendererPresentationRecord {
        if let record = try? rendererControlRecord(
            presentation: presentation,
            binding: binding
        ) {
            return record
        }
        guard let presentation, presentation.visible else {
            throw TerminalBackendClientError.rendererNotReady
        }
        _ = try await configureRenderer(
            presentation,
            binding: binding,
            connection: connection
        )
        return try rendererControlRecord(
            presentation: presentation,
            binding: binding
        )
    }

    private func finishTerminalReceipt(
        _ receipt: BackendTerminalOperationReceipt,
        expectedKind: BackendTerminalOperationKind,
        requestID: UUID,
        surfaceID: SurfaceID,
        connection: TerminalBackendConnectedSession
    ) async throws -> BackendTerminalOperationReceipt {
        guard receipt.requestID == requestID,
              receipt.kind == expectedKind,
              receipt.sequence != nil,
              receipt.leaseGeneration != nil else {
            throw BackendProtocolError.malformedMessage
        }
        terminalRequestsAwaitingRecovery.remove(requestID)
        await acknowledgeTerminalReceipt(
            surfaceID: surfaceID,
            requestID: requestID,
            on: connection
        )
        switch receipt.status {
        case .applied:
            return receipt
        case .indeterminate:
            throw BackendTerminalControlError.indeterminate(
                requestID: requestID,
                diagnostic: receipt.diagnostic ?? "indeterminate PTY write"
            )
        case .unknown:
            throw BackendProtocolError.malformedMessage
        }
    }

    private func acknowledgeTerminalReceipt(
        surfaceID: SurfaceID,
        requestID: UUID,
        on connection: TerminalBackendConnectedSession
    ) async {
        let acknowledgement = PendingTerminalReceiptAcknowledgement(
            surfaceID: surfaceID,
            requestID: requestID
        )
        pendingTerminalReceiptAcknowledgements.insert(acknowledgement)
        do {
            _ = try await connection.session.acknowledgeTerminalRequest(
                surfaceID: surfaceID,
                requestID: requestID
            )
            pendingTerminalReceiptAcknowledgements.remove(acknowledgement)
        } catch {
            // The applied receipt is already definitive. A later connection
            // retries this idempotent acknowledgement without resending input.
        }
    }

    private func flushTerminalReceiptAcknowledgements(
        on connection: TerminalBackendConnectedSession
    ) async {
        for acknowledgement in Array(pendingTerminalReceiptAcknowledgements) {
            do {
                _ = try await connection.session.acknowledgeTerminalRequest(
                    surfaceID: acknowledgement.surfaceID,
                    requestID: acknowledgement.requestID
                )
                pendingTerminalReceiptAcknowledgements.remove(acknowledgement)
            } catch {
                return
            }
        }
    }

    private func rendererControlRecord(
        presentation: TerminalBackendPresentationDescriptor?,
        binding: TerminalBackendTerminalBinding
    ) throws -> RendererPresentationRecord {
        guard let presentation,
              presentation.visible,
              let record = rendererPresentations[presentation.presentationID],
              record.binding.appSurfaceID == binding.appSurfaceID,
              record.binding.surfaceID == binding.surfaceID,
              record.descriptor.visible,
              record.receipt != nil else {
            throw TerminalBackendClientError.rendererNotReady
        }
        return record
    }

    private func processMetadata(
        for binding: TerminalBackendTerminalBinding,
        connection: TerminalBackendConnectedSession
    ) async throws -> TerminalExternalProcessMetadata {
        let process = try await connection.session.terminalProcessInfo(
            surface: binding.surfaceHandle
        )
        return TerminalExternalProcessMetadata(
            foregroundProcessID: process.processID.map(Int.init),
            controllingTTYName: process.controllingTTYName
        )
    }

    private enum ConnectionSupervisorStep: Sendable {
        case observe(Task<Void, Never>)
        case retry
        case stop
    }

    /// Starts one process-lifetime recovery loop. A cycle performs the bounded
    /// connection policy, then waits for that exact session's observation task
    /// to finish before replacing it. The task never owns a session while the
    /// coordinator is explicitly disconnected.
    private func ensureConnectionSupervisor() {
        guard connectionSupervisorTask == nil else { return }
        let supervisorID = UUID()
        connectionSupervisorID = supervisorID
        let recoveryCycleDelay = reconnectPolicy.recoveryCycleDelay
        connectionSupervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let step = await self?.beginConnectionSupervisorCycle(
                    supervisorID: supervisorID
                ) else { return }
                switch step {
                case .observe(let observationTask):
                    await observationTask.value
                case .retry:
                    do {
                        if recoveryCycleDelay > .zero {
                            try await ContinuousClock().sleep(for: recoveryCycleDelay)
                        } else {
                            await Task.yield()
                        }
                    } catch is CancellationError {
                        await self?.connectionSupervisorDidFinish(
                            supervisorID: supervisorID
                        )
                        return
                    } catch {
                        await self?.connectionSupervisorDidFinish(
                            supervisorID: supervisorID
                        )
                        return
                    }
                case .stop:
                    await self?.connectionSupervisorDidFinish(
                        supervisorID: supervisorID
                    )
                    return
                }
            }
            await self?.connectionSupervisorDidFinish(supervisorID: supervisorID)
        }
    }

    private func beginConnectionSupervisorCycle(
        supervisorID: UUID
    ) async -> ConnectionSupervisorStep {
        guard connectionSupervisorID == supervisorID, !Task.isCancelled else {
            return .stop
        }
        do {
            _ = try await connectedSession()
            guard connectionSupervisorID == supervisorID, !Task.isCancelled else {
                return .stop
            }
            guard let eventTask else {
                return .retry
            }
            return .observe(eventTask)
        } catch is CancellationError {
            return .stop
        } catch {
            return Self.shouldContinueSupervising(after: error) ? .retry : .stop
        }
    }

    private func connectionSupervisorDidFinish(supervisorID: UUID) {
        guard connectionSupervisorID == supervisorID else { return }
        connectionSupervisorTask = nil
    }

    private func connectedSession(
        for binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendConnectedSession {
        let connection = try await connectedSession()
        guard connection.readiness.authority == binding.authority else {
            throw TerminalBackendClientError.authorityChanged(
                expected: binding.authority,
                actual: connection.readiness.authority
            )
        }
        return connection
    }

    private func canonicalMutationContext(
        command: String
    ) async throws -> (
        connection: TerminalBackendConnectedSession,
        snapshot: TopologySnapshot
    ) {
        let connection = try await connectedSession()
        let compatibility = try await connection.session.backendCompatibility()
        guard connected?.readiness == connection.readiness else {
            throw TerminalBackendTopologyMutationError.canonicalSnapshotUnavailable
        }
        if case .readOnly(let diagnostic) = compatibility {
            throw BackendProtocolError.mutationUnavailableInReadOnlyMode(
                command: command,
                compatibility: diagnostic
            )
        }
        guard let snapshot = latestSnapshot else {
            throw TerminalBackendTopologyMutationError.canonicalSnapshotUnavailable
        }
        guard snapshot.authority == connection.readiness.authority else {
            throw TerminalBackendTopologyMutationError.authorityChanged(
                expected: connection.readiness.authority,
                actual: snapshot.authority
            )
        }
        return (connection, snapshot)
    }

    private func performCanonicalTopologyMutation<Result: Sendable>(
        command: String,
        requestID: UUID,
        receipt receiptForResult: @Sendable (Result) -> BackendTopologyMutationReceipt,
        operation: @Sendable (
            any TerminalBackendSessionServing,
            BackendTopologyMutationExpectation
        ) async throws -> Result
    ) async throws -> Result {
        await acquireTopologyMutationPermit()
        defer { releaseTopologyMutationPermit() }
        try Task.checkCancellation()
        let context = try await canonicalMutationContext(command: command)
        let expectation = try await context.connection.session.makeTopologyMutationExpectation(
            requestID: requestID,
            authority: context.snapshot.authority,
            revision: context.snapshot.revision
        )
        let result = try await operation(context.connection.session, expectation)
        let receipt = receiptForResult(result)
        let (expectedRevision, revisionOverflow) = receipt.baseRevision.addingReportingOverflow(1)
        guard receipt.requestID == requestID,
              receipt.authority == expectation.authority,
              !revisionOverflow,
              receipt.revision == expectedRevision else {
            throw BackendProtocolError.peerIdentityMismatch
        }
        try await awaitCanonicalTopologyReceipt(receipt, from: context.connection)
        return result
    }

    private func acquireTopologyMutationPermit() async {
        if !topologyMutationInFlight {
            topologyMutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            topologyMutationWaiters.append(continuation)
        }
    }

    private func releaseTopologyMutationPermit() {
        if topologyMutationWaiters.isEmpty {
            topologyMutationInFlight = false
        } else {
            topologyMutationWaiters.removeFirst().resume()
        }
    }

    private func awaitCanonicalTopologyReceipt(
        _ receipt: BackendTopologyMutationReceipt,
        from connection: TerminalBackendConnectedSession
    ) async throws {
        guard connected?.readiness == connection.readiness else {
            throw TerminalBackendTopologyMutationError.canonicalSnapshotUnavailable
        }
        if let latestSnapshot,
           latestSnapshot.authority == receipt.authority,
           latestSnapshot.revision >= receipt.revision {
            return
        }
        let identifier = UUID()
        try await withCheckedThrowingContinuation { continuation in
            topologyRevisionWaiters[identifier] = TopologyRevisionWaiter(
                authority: receipt.authority,
                revision: receipt.revision,
                continuation: continuation
            )
        }
    }

    private func resumeTopologyRevisionWaiters(with snapshot: TopologySnapshot) {
        let ready = topologyRevisionWaiters.filter { _, waiter in
            waiter.authority == snapshot.authority && waiter.revision <= snapshot.revision
        }
        for (identifier, waiter) in ready {
            topologyRevisionWaiters.removeValue(forKey: identifier)
            waiter.continuation.resume()
        }
    }

    private func failTopologyRevisionWaiters(_ error: any Error) {
        let waiters = topologyRevisionWaiters.values
        topologyRevisionWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func topologyMutationIndex(_ index: Int) throws -> UInt64 {
        guard let index = UInt64(exactly: index) else {
            throw TerminalBackendTopologyMutationError.invalidIndex(index)
        }
        return index
    }

    private func resolveWorkspace(
        _ workspaceID: WorkspaceID,
        in snapshot: TopologySnapshot
    ) throws -> CanonicalWorkspace {
        guard let workspace = snapshot.topology.workspaces.first(where: {
            $0.uuid == workspaceID
        }) else {
            throw TerminalBackendTopologyMutationError.workspaceNotFound(workspaceID)
        }
        return workspace
    }

    private func resolvePane(
        _ paneID: PaneID,
        in snapshot: TopologySnapshot
    ) throws -> CanonicalPane {
        for workspace in snapshot.topology.workspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.uuid == paneID }) {
                    return pane
                }
            }
        }
        throw TerminalBackendTopologyMutationError.paneNotFound(paneID)
    }

    private func resolveSurface(
        _ surfaceID: SurfaceID,
        in snapshot: TopologySnapshot
    ) throws -> CanonicalSurface {
        try resolveSurfaceAndPane(surfaceID, in: snapshot).surface
    }

    private func resolveSurfaceAndPane(
        _ surfaceID: SurfaceID,
        in snapshot: TopologySnapshot
    ) throws -> (surface: CanonicalSurface, pane: CanonicalPane) {
        for workspace in snapshot.topology.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let surface = pane.tabs.first(where: { $0.uuid == surfaceID }) {
                        return (surface, pane)
                    }
                }
            }
        }
        throw TerminalBackendTopologyMutationError.surfaceNotFound(surfaceID)
    }

    private func connectedSession() async throws -> TerminalBackendConnectedSession {
        ensureConnectionSupervisor()
        if let connected { return connected }
        if let connectionTask { return try await connectionTask.value }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        let readinessProvider = readinessProvider
        let sessionFactory = sessionFactory
        let reconnectPolicy = reconnectPolicy
        let task = Task {
            try await Self.connect(
                readinessProvider: readinessProvider,
                sessionFactory: sessionFactory,
                reconnectPolicy: reconnectPolicy
            )
        }
        connectionTask = task
        do {
            let result = try await task.value
            guard connectionAttemptID == attemptID else {
                await result.session.close()
                throw CancellationError()
            }
            let compatibility: BackendCompatibilityResult
            do {
                compatibility = try await result.session.backendCompatibility()
            } catch {
                await result.session.close()
                throw error
            }
            guard connectionAttemptID == attemptID else {
                await result.session.close()
                throw CancellationError()
            }
            connectionTask = nil
            connected = result
            await compatibilityReporter(compatibility)
            guard connectionAttemptID == attemptID,
                  connected?.readiness == result.readiness else {
                await result.session.close()
                throw CancellationError()
            }
            if let snapshot = result.snapshot {
                latestSnapshot = snapshot
                publishSnapshot(snapshot)
                publishTopology(.snapshot(snapshot))
            } else {
                latestSnapshot = nil
                latestActivitySnapshot = nil
            }
            observe(result, attemptID: attemptID)
            frontendRecoveryGeneration = nil
            if case .readWrite = compatibility {
                await flushTerminalReceiptAcknowledgements(on: result)
                if let workers = try? await result.session.rendererWorkers(),
                   connected?.readiness == result.readiness {
                    do {
                        try registerRendererWorkers(workers, for: result)
                    } catch {
                        await invalidate(result)
                        throw error
                    }
                    publishRenderer(.reconnected(workers))
                }
            }
            guard connected?.readiness == result.readiness else {
                return try await connectedSession()
            }
            return result
        } catch {
            if connectionAttemptID == attemptID {
                connectionTask = nil
            }
            throw error
        }
    }

    private func observe(
        _ connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let events = await connection.session.events()
            for await event in events {
                guard let self else { return }
                switch event {
                case .snapshot(let snapshot):
                    await self.receivedSnapshot(
                        snapshot,
                        from: connection,
                        attemptID: attemptID
                    )
                case .delta(let delta):
                    await self.receivedDelta(
                        delta,
                        from: connection,
                        attemptID: attemptID
                    )
                case .terminalActivitySnapshot(let snapshot):
                    await self.receivedActivitySnapshot(snapshot, from: connection)
                case .terminalActivity, .terminalActivityReceipt:
                    if let snapshot = await connection.session.currentTerminalActivitySnapshot() {
                        await self.receivedActivitySnapshot(snapshot, from: connection)
                    }
                case .rendererWorkerChanged(let changed):
                    await self.receivedWorkerChanged(changed, from: connection)
                case .rendererPresentationReady(let ready):
                    await self.receivedPresentationReady(ready, from: connection)
                case .disconnected:
                    await self.connectionDidEnd(connection, attemptID: attemptID)
                    return
                }
            }
            await self?.connectionDidEnd(connection, attemptID: attemptID)
        }
    }

    private func receivedSnapshot(
        _ snapshot: TopologySnapshot,
        from connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async {
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        do {
            try await reconcileTerminalInputOwners(
                with: snapshot,
                connection: connection,
                attemptID: attemptID
            )
        } catch {
            if connectionAttemptID == attemptID,
               connected?.readiness == connection.readiness {
                await invalidate(connection)
            }
            return
        }
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        latestSnapshot = snapshot
        resumeTopologyRevisionWaiters(with: snapshot)
        publishSnapshot(snapshot)
        publishTopology(.snapshot(snapshot))
    }

    private func receivedDelta(
        _ delta: TopologyDelta,
        from connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async {
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        let snapshot = TopologySnapshot(
            authority: delta.authority,
            revision: delta.revision,
            topology: delta.replacement
        )
        do {
            try await reconcileTerminalInputOwners(
                with: snapshot,
                connection: connection,
                attemptID: attemptID
            )
        } catch {
            if connectionAttemptID == attemptID,
               connected?.readiness == connection.readiness {
                await invalidate(connection)
            }
            return
        }
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        latestSnapshot = snapshot
        resumeTopologyRevisionWaiters(with: snapshot)
        publishSnapshot(snapshot)
        publishTopology(.delta(delta))
    }

    private func receivedPresentationReady(
        _ ready: BackendRendererPresentationReady,
        from connection: TerminalBackendConnectedSession
    ) async {
        guard connected?.readiness == connection.readiness else { return }
        guard let entry = rendererPresentations.first(where: { _, record in
            guard !record.removalPending else { return false }
            guard let receipt = record.receipt else { return false }
            return receipt.presentationID == ready.presentationID
                && receipt.workspaceID == ready.workspaceID
                && receipt.rendererEpoch == ready.rendererEpoch
                && receipt.terminalID == ready.terminalID
                && receipt.terminalEpoch == ready.terminalEpoch
                && receipt.rendererGeneration == ready.presentationGeneration
        }) else { return }
        var record = entry.value
        do {
            record.workerIdentity = try registerRendererWorker(
                daemonInstanceID: record.binding.authority.daemonInstanceID.rawValue,
                rendererEpoch: ready.rendererEpoch,
                processID: ready.workerProcessID,
                processInstanceToken: ready.workerProcessInstanceToken
            )
        } catch {
            await invalidate(connection)
            return
        }
        record.ready = ready
        rendererPresentations[entry.key] = record
        guard let attachment = try? rendererAttachment(record) else { return }
        publishRenderer(
            .presentationReady(
                presentationID: entry.key,
                attachment: attachment
            )
        )
    }

    private func receivedActivitySnapshot(
        _ snapshot: BackendTerminalActivitySnapshot,
        from connection: TerminalBackendConnectedSession
    ) {
        guard connected?.readiness == connection.readiness else { return }
        latestActivitySnapshot = snapshot
        publishActivity(snapshot)
    }

    private func receivedWorkerChanged(
        _ changed: BackendRendererWorkerChanged,
        from connection: TerminalBackendConnectedSession
    ) async {
        guard connected?.readiness == connection.readiness else { return }
        do {
            _ = try registerRendererWorker(
                daemonInstanceID: connection.readiness.authority.daemonInstanceID.rawValue,
                rendererEpoch: changed.rendererEpoch ?? 0,
                processID: changed.processID,
                processInstanceToken: changed.processInstanceToken
            )
        } catch {
            await invalidate(connection)
            return
        }
        for (identifier, var record) in rendererPresentations
            where record.binding.workspaceID == changed.workspaceID {
            guard let receipt = record.receipt else { continue }
            let priorWorkerDied = changed.priorRendererEpoch == receipt.rendererEpoch
                && (changed.rendererEpoch != receipt.rendererEpoch
                    || changed.state != .ready)
            if priorWorkerDied {
                record.receipt = nil
                record.ready = nil
                rendererPresentations[identifier] = record
            }
        }
        publishRenderer(.workerChanged(changed))
    }

    private func connectionDidEnd(
        _ connection: TerminalBackendConnectedSession,
        attemptID: UUID
    ) async {
        guard connectionAttemptID == attemptID,
              connected?.readiness == connection.readiness else { return }
        discardTerminalInputAuthorityState()
        connected = nil
        latestSnapshot = nil
        failTopologyRevisionWaiters(BackendCanonicalSessionError.notConnected)
        publishRenderer(.connectionLost(connection.readiness.authority))
        publishTopology(.disconnected(connection.readiness.authority))
        await compatibilityReporter(nil)
        eventTask = nil
        connectionAttemptID = UUID()
        // The old protocol client must release its socket before the supervisor
        // starts another bounded recovery cycle.
        await connection.session.close()
    }

    private func invalidate(_ connection: TerminalBackendConnectedSession) async {
        guard connected?.readiness == connection.readiness else { return }
        // A semantic or identity violation is fail-closed. Stop background
        // recovery so it cannot silently trust a replacement session after the
        // caller has rejected the current authority. A later explicit client
        // operation may start a fresh supervisor.
        connectionSupervisorID = UUID()
        connectionSupervisorTask?.cancel()
        connectionSupervisorTask = nil
        discardTerminalInputAuthorityState()
        connected = nil
        latestSnapshot = nil
        failTopologyRevisionWaiters(BackendCanonicalSessionError.notConnected)
        publishRenderer(.connectionLost(connection.readiness.authority))
        publishTopology(.disconnected(connection.readiness.authority))
        await compatibilityReporter(nil)
        eventTask?.cancel()
        eventTask = nil
        connectionAttemptID = UUID()
        await connection.session.close()
    }

    private func publishRenderer(_ event: TerminalBackendRendererEvent) {
        var overflowed: [UUID] = []
        for (identifier, continuation) in rendererContinuations {
            if case .dropped = continuation.yield(event) {
                continuation.finish()
                overflowed.append(identifier)
            }
        }
        for identifier in overflowed {
            rendererContinuations.removeValue(forKey: identifier)
        }
    }

    private func publishSnapshot(_ snapshot: TopologySnapshot) {
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func publishTopology(_ event: TerminalBackendTopologyStreamEvent) {
        for continuation in topologyContinuations.values {
            // A dropped older element is intentional coalescing. The newest
            // snapshot/delta is self-contained and the stream must stay alive.
            continuation.yield(event)
        }
    }

    private func publishActivity(_ snapshot: BackendTerminalActivitySnapshot) {
        for continuation in activityContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeRendererContinuation(_ identifier: UUID) {
        rendererContinuations.removeValue(forKey: identifier)
    }

    private func removeSnapshotContinuation(_ identifier: UUID) {
        snapshotContinuations.removeValue(forKey: identifier)
    }

    private func removeTopologyContinuation(_ identifier: UUID) {
        topologyContinuations.removeValue(forKey: identifier)
    }

    private func removeActivityContinuation(_ identifier: UUID) {
        activityContinuations.removeValue(forKey: identifier)
    }

    private static func connect(
        readinessProvider: ReadinessProvider,
        sessionFactory: SessionFactory,
        reconnectPolicy: TerminalBackendReconnectPolicy
    ) async throws -> TerminalBackendConnectedSession {
        var nextDelayIndex = 0
        while true {
            do {
                let readiness = try await resolveReadiness(readinessProvider)
                let session = sessionFactory(readiness)
                do {
                    let snapshot = try await session.connect()
                    if let snapshot {
                        guard snapshot.authority == readiness.authority,
                              snapshot.revision >= readiness.topologyRevision else {
                            throw BackendProtocolError.peerIdentityMismatch
                        }
                    }
                    return TerminalBackendConnectedSession(
                        readiness: readiness,
                        session: session,
                        snapshot: snapshot
                    )
                } catch {
                    await session.close()
                    throw error
                }
            } catch {
                guard shouldRetry(error) else {
                    throw error
                }
                guard nextDelayIndex < reconnectPolicy.delays.count else {
                    if error is TerminalBackendClientError { throw error }
                    throw TerminalBackendClientError.reconnectExhausted(
                        String(describing: error)
                    )
                }
                let delay = reconnectPolicy.delays[nextDelayIndex]
                nextDelayIndex += 1
                if delay > .zero {
                    // This is the retry policy's bounded, cancellable backoff.
                    try await ContinuousClock().sleep(for: delay)
                }
            }
        }
    }

    private static func resolveReadiness(
        _ readinessProvider: ReadinessProvider
    ) async throws -> BackendServiceReadiness {
        switch try await readinessProvider() {
        case .ready(let readiness):
            return readiness
        case .disabled:
            throw TerminalBackendClientError.disabled
        case .requiresApproval:
            throw TerminalBackendClientError.requiresApproval
        case .missingBundleItem(let item):
            throw TerminalBackendClientError.missingBundleItem(item)
        case .serviceNotFound:
            throw TerminalBackendClientError.serviceNotFound
        case .backendUnavailable:
            throw TerminalBackendClientError.unavailable
        }
    }

    private static func shouldContinueSupervising(after error: any Error) -> Bool {
        if let clientError = error as? TerminalBackendClientError {
            switch clientError {
            case .unavailable, .reconnectExhausted, .requiresApproval, .serviceNotFound:
                return true
            case .disabled, .missingBundleItem, .authorityChanged, .unsupportedMutation,
                 .presentationUnavailable, .rendererNotReady:
                return false
            }
        }
        return shouldRetry(error)
    }

    private static func shouldRetry(_ error: any Error) -> Bool {
        if error as? TerminalBackendClientError == .unavailable { return true }
        if let protocolError = error as? BackendProtocolError {
            switch protocolError {
            case .connectionClosed, .notConnected:
                return true
            default:
                return false
            }
        }
        let cocoaError = error as NSError
        guard cocoaError.domain == NSPOSIXErrorDomain else { return false }
        switch Int32(cocoaError.code) {
        case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN:
            return true
        default:
            return false
        }
    }
}

private extension TerminalExternalKeyAction {
    var backendAction: BackendTerminalKeyAction {
        switch self {
        case .press: .press
        case .release: .release
        case .repeat: .repeat
        }
    }
}

private extension TerminalExternalMouseAction {
    var backendAction: BackendTerminalMouseAction {
        switch self {
        case .press: .press
        case .release: .release
        case .motion: .motion
        }
    }
}

private extension TerminalExternalMouseButton {
    var backendButton: BackendTerminalMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .wheelUp: .wheelUp
        case .wheelDown: .wheelDown
        case .wheelLeft: .wheelLeft
        case .wheelRight: .wheelRight
        }
    }
}

private extension TerminalBackendMutationOutcome {
    mutating func install(_ response: BackendTerminalActionResponse) {
        actionHandled = response.handled
        clipboardText = response.clipboardText
        install(response.state)
    }

    mutating func install(_ state: BackendTerminalUXState) {
        copyModeActive = state.copyMode
        mouseTracking = state.mouseTracking
        copyCursor = state.copyCursor?.externalPoint
        cursor = state.cursor?.externalCursor
        terminalUXWasRead = true
        selection = state.selection?.externalSelection
        selectionWasRead = true
        search = state.search.externalSearch
        viewportState = state.viewport.externalViewport
    }
}

private extension BackendTerminalSelection {
    var externalSelection: TerminalExternalSelection? {
        guard hasSelection, let range else { return nil }
        return TerminalExternalSelection(
            text: text ?? "",
            start: range.start.externalPoint,
            end: range.end.externalPoint,
            topLeft: range.topLeft.externalPoint,
            bottomRight: range.bottomRight.externalPoint,
            rectangle: range.rectangle
        )
    }
}

private extension BackendTerminalCursorState {
    var externalCursor: TerminalExternalCursorState {
        TerminalExternalCursorState(column: column, row: row, visible: visible)
    }
}

private extension BackendTerminalCellPoint {
    var externalPoint: TerminalExternalCellPoint {
        TerminalExternalCellPoint(column: column, row: row)
    }
}

private extension BackendTerminalSearchState {
    var externalSearch: TerminalExternalSearchState {
        TerminalExternalSearchState(
            active: active,
            query: query,
            selectedMatch: selectedMatch,
            totalMatches: totalMatches
        )
    }
}

private extension BackendTerminalViewportState {
    var externalViewport: TerminalExternalViewportState {
        TerminalExternalViewportState(
            totalRows: totalRows,
            offset: offset,
            visibleRows: visibleRows
        )
    }
}

private extension TerminalExternalSelectionOperation {
    var backendOperation: BackendTerminalSelectionOperation {
        switch self {
        case .read: .read
        case .clear: .clear
        case .selectAll: .selectAll
        }
    }
}

private extension TerminalExternalCopyModeOperation {
    var backendOperation: BackendTerminalCopyModeOperation {
        switch self {
        case .enter: .enter
        case .exit: .exit
        case .startSelection: .startSelection
        case .startLineSelection: .startLineSelection
        case .clearSelection: .clearSelection
        case .adjust: .adjust
        case .copyAndExit: .copyAndExit
        }
    }
}

private extension TerminalExternalCopyModeAdjustment {
    var backendAdjustment: BackendTerminalCopyModeAdjustment {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .beginningOfLine: .beginningOfLine
        case .endOfLine: .endOfLine
        }
    }
}

private extension TerminalExternalSearchOperation {
    var backendOperation: BackendTerminalSearchOperation {
        switch self {
        case .start: .start
        case .update: .update
        case .next: .next
        case .previous: .previous
        case .end: .end
        }
    }
}

private extension TerminalExternalScrollOperation {
    var backendOperation: BackendTerminalScrollOperation {
        switch self {
        case .lines: .lines
        case .pages: .pages
        case .top: .top
        case .bottom: .bottom
        }
    }
}

private extension TerminalRenderPixelFormat {
    var backendPixelFormat: BackendRendererPixelFormat {
        switch self {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}

private extension BackendRendererPixelFormat {
    var terminalPixelFormat: TerminalRenderPixelFormat {
        switch self {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}

private extension TerminalRenderColorSpace {
    var backendColorSpace: BackendRendererColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        case .extendedLinearSRGB: .extendedLinearSRGB
        }
    }
}

private extension BackendRendererColorSpace {
    var terminalColorSpace: TerminalRenderColorSpace {
        switch self {
        case .sRGB: .sRGB
        case .displayP3: .displayP3
        case .extendedLinearSRGB: .extendedLinearSRGB
        }
    }
}

private let terminalAccessibilitySchemaVersion: UInt32 = 1
private let terminalAccessibilityMaximumRows = 4_096
private let terminalAccessibilityMaximumCells = 65_536
private let terminalAccessibilityMaximumUTF16Units = 1_048_576
private let terminalAccessibilityMaximumTextBytes = 1_048_576
private let terminalAccessibilityMaximumLinks = 1_024

extension BackendTerminalAccessibilitySnapshot {
    func externalSnapshot(
        appSurfaceID: UUID,
        appPresentationID: UUID
    ) throws -> TerminalAccessibilitySnapshot {
        guard schemaVersion == terminalAccessibilitySchemaVersion,
              contentSequence > 0,
              columns > 0,
              rows > 0,
              text.utf8.count <= terminalAccessibilityMaximumTextBytes,
              text.utf16.count <= terminalAccessibilityMaximumUTF16Units,
              lines.count <= terminalAccessibilityMaximumRows,
              links.count <= terminalAccessibilityMaximumLinks,
              Int(rows) == lines.count else {
            throw BackendProtocolError.malformedMessage
        }
        let utf16Count = text.utf16.count
        let utf16Text = text as NSString
        var totalCells = 0
        var previousLineEnd = 0
        let externalLines = try lines.enumerated().map { index, line in
            let range = try line.utf16Range.externalRange(maximum: utf16Count)
            let expectedLocation = index == 0 ? 0 : previousLineEnd + 1
            let expectedRow = viewportOffset.addingReportingOverflow(UInt64(index))
            guard !expectedRow.overflow,
                  line.row == expectedRow.partialValue,
                  range.location == expectedLocation,
                  range.length > 0 else {
                throw BackendProtocolError.malformedMessage
            }
            previousLineEnd = range.location + range.length
            if index + 1 < lines.count {
                guard previousLineEnd < utf16Count,
                      utf16Text.character(at: previousLineEnd) == 0x0A else {
                    throw BackendProtocolError.malformedMessage
                }
            } else if previousLineEnd != utf16Count {
                throw BackendProtocolError.malformedMessage
            }
            totalCells += line.cells.count
            guard totalCells <= terminalAccessibilityMaximumCells else {
                throw BackendProtocolError.malformedMessage
            }
            var expectedColumn = 0
            var expectedCellLocation = range.location
            let cells = try line.cells.map { cell in
                let column = Int(cell.column)
                let span = Int(cell.columnSpan)
                let cellRange = try cell.utf16Range.externalRange(maximum: utf16Count)
                guard span > 0,
                      column == expectedColumn,
                      column + span <= Int(columns),
                      cellRange.location == expectedCellLocation,
                      cellRange.length > 0,
                      cellRange.location + cellRange.length <= previousLineEnd else {
                    throw BackendProtocolError.malformedMessage
                }
                expectedColumn = column + span
                expectedCellLocation = cellRange.location + cellRange.length
                return TerminalAccessibilityCell(
                    column: column,
                    columnSpan: span,
                    utf16Range: cellRange
                )
            }
            guard expectedColumn == Int(columns), expectedCellLocation == previousLineEnd else {
                throw BackendProtocolError.malformedMessage
            }
            return TerminalAccessibilityLine(row: line.row, utf16Range: range, cells: cells)
        }
        var selectionTextBytes = 0
        let externalSelections = try selections.map { selection in
            selectionTextBytes += selection.text.utf8.count
            guard selectionTextBytes <= terminalAccessibilityMaximumTextBytes,
                  selection.text.utf16.count <= terminalAccessibilityMaximumUTF16Units else {
                throw BackendProtocolError.malformedMessage
            }
            var previousRangeEnd = 0
            let ranges = try selection.utf16Ranges.map {
                let range = try $0.externalRange(maximum: utf16Count)
                guard range.length > 0, range.location >= previousRangeEnd else {
                    throw BackendProtocolError.malformedMessage
                }
                previousRangeEnd = range.location + range.length
                return range
            }
            return TerminalAccessibilitySelection(
                text: selection.text,
                utf16Ranges: ranges
            )
        }
        var linkIDs = Set<String>()
        var linkTargetBytes = 0
        let externalLinks = try links.map { link in
            linkTargetBytes += link.target.utf8.count
            guard !link.id.isEmpty, link.id.utf8.count <= 128,
                  !link.target.isEmpty, link.target.utf8.count <= 4_096,
                  linkTargetBytes <= terminalAccessibilityMaximumLinks * 4_096,
                  linkIDs.insert(link.id).inserted,
                  link.startColumn <= link.endColumn,
                  Int(link.endColumn) < Int(columns),
                  let line = externalLines.first(where: { $0.row == link.row }),
                  let first = line.cells.first(where: {
                    Int(link.startColumn) >= $0.column
                        && Int(link.startColumn) < $0.column + $0.columnSpan
                  }),
                  let last = line.cells.first(where: {
                    Int(link.endColumn) >= $0.column
                        && Int(link.endColumn) < $0.column + $0.columnSpan
                  }) else {
                throw BackendProtocolError.malformedMessage
            }
            let range = try link.utf16Range.externalRange(maximum: utf16Count)
            let expectedEnd = last.utf16Range.location + last.utf16Range.length
            guard range.length > 0,
                  range.location == first.utf16Range.location,
                  range.location + range.length == expectedEnd else {
                throw BackendProtocolError.malformedMessage
            }
            return TerminalAccessibilityLink(
                id: link.id,
                target: link.target,
                utf16Range: range,
                row: link.row,
                startColumn: Int(link.startColumn),
                endColumn: Int(link.endColumn)
            )
        }
        let externalCursor: TerminalAccessibilityCursor?
        if let cursor {
            let lineIndex = Int(cursor.line)
            let column = Int(cursor.column)
            let insertionRange = try cursor.insertionRange.externalRange(maximum: utf16Count)
            guard externalLines.indices.contains(lineIndex),
                  externalLines[lineIndex].row == cursor.row,
                  column < Int(columns),
                  insertionRange.length == 0,
                  let cell = externalLines[lineIndex].cells.first(where: {
                    column >= $0.column && column < $0.column + $0.columnSpan
                  }),
                  insertionRange.location == cell.utf16Range.location else {
                throw BackendProtocolError.malformedMessage
            }
            externalCursor = TerminalAccessibilityCursor(
                column: column,
                row: cursor.row,
                insertionRange: insertionRange,
                line: lineIndex
            )
        } else {
            externalCursor = nil
        }
        return TerminalAccessibilitySnapshot(
            schemaVersion: schemaVersion,
            surfaceID: appSurfaceID,
            presentationID: appPresentationID,
            presentationGeneration: presentationGeneration,
            contentSequence: contentSequence,
            terminalRevision: terminalRevision,
            contentRevision: contentRevision,
            viewportRevision: viewportRevision,
            viewportOffset: viewportOffset,
            columns: Int(columns),
            rows: Int(rows),
            text: text,
            lines: externalLines,
            cursor: externalCursor,
            selections: externalSelections,
            links: externalLinks,
            focused: focused
        )
    }
}

private extension BackendTerminalAccessibilityRange {
    func externalRange(maximum: Int) throws -> TerminalAccessibilityRange {
        let location = Int(self.location)
        let length = Int(self.length)
        guard location <= maximum, length <= maximum - location else {
            throw BackendProtocolError.malformedMessage
        }
        return TerminalAccessibilityRange(location: location, length: length)
    }
}

private extension UUID {
    static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }

    func multipliedClamped(by other: UInt64) -> UInt64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : result
    }
}

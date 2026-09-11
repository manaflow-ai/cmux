import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxSettings
import Foundation
import OSLog

/// The sole Mac IROH owner for a selected Stack team and opted-in installation.
@MainActor
final class MobileHostIrxRuntime: MobileHostPairingRuntime {
    static let shared = MobileHostIrxRuntime(publishesPublicHostStatus: true)
    nonisolated static let forceRelayDefaultsKey = "cmux.iroh.v2.force-relay"
    nonisolated static let pathModeDefaultsKey = "cmux.iroh.v2.path-mode"
    nonisolated static let maximumActivationRetryDelay: TimeInterval = 5 * 60
    nonisolated static var forceRelayOnly: Bool {
        ProcessInfo.processInfo.environment["CMUX_IROH_V2_FORCE_RELAY"] == "1"
            || UserDefaults.standard.string(forKey: "cmux.iroh.v2.config.CMUX_IROH_V2_FORCE_RELAY") == "1"
            || UserDefaults.standard.bool(forKey: forceRelayDefaultsKey)
            || UserDefaults.standard.string(forKey: pathModeDefaultsKey) == "relay-only"
    }
    nonisolated static var pathMode: IrxPathMode {
        if forceRelayOnly { return .relayOnly }
        return UserDefaults.standard.string(forKey: pathModeDefaultsKey) == "direct-only" ? .directOnly : .automatic
    }
    nonisolated static let journal = IrxJournal(subsystem: "dev.cmux", category: "irx-host",
        journalFileURL: URL(fileURLWithPath: "/tmp/cmux-irx-journal-mac-\(MobileHostIdentity.instanceTag()).jsonl"))

    nonisolated static func activationRetryDelay(after error: any Error, failureCount: Int, jitterUnitInterval: Double) -> TimeInterval {
        let ladder = min(5 * pow(2, Double(min(max(failureCount, 0), 16))), maximumActivationRetryDelay)
        let floor = TimeInterval(max(0, (error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0))
        let base = max(ladder, floor)
        return base + min(max(jitterUnitInterval, 0), 1) * base * 0.25
    }

    enum SettingsPhase: Equatable { case idle, activating, active, failed }
    private let managedDevicePolicy: ManagedDevicePolicy
    private let pairingEnabled: @MainActor () -> Bool
    private let publishesPublicHostStatus: Bool
    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var activeScope: AuthenticatedTeamScope?
    private var signingOutScope: AuthenticatedTeamScope?
    private var wantsHost = true
    private var requiresTransition = false
    private var generationToken = UUID()
    private var activationTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    private var permissionExpiryTask: Task<Void, Never>?
    private var acceptLoop: Task<Void, Never>?
    private var admission: V2InboundAdmissionAuthority?
    private var registry: IrxServerSessionRegistry?
    private var identity: IrxIdentity?
    private(set) var controlService: V2ControlService?
    private(set) var endpointSupervisor: IrxEndpointSupervisor?
    private(set) var cachedState: V2CachedState?
    private var listenerContinuations: [UUID: AsyncStream<MobileHostListenerState>.Continuation] = [:]
    private(set) var listenerState = MobileHostListenerState() {
        didSet {
            guard listenerState != oldValue else { return }
            for continuation in listenerContinuations.values { continuation.yield(listenerState) }
            if publishesPublicHostStatus {
                NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
            }
        }
    }
    private(set) var settingsPhase: SettingsPhase = .idle
    private(set) var hadLiveDiscoveryThisRun = false
    var irxSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var irxSettingsRefreshTask: Task<Void, Never>?

    init(managedDevicePolicy: ManagedDevicePolicy = ManagedDevicePolicy(), publishesPublicHostStatus: Bool = false,
         pairingEnabled: @escaping @MainActor () -> Bool = { MobileHostService.isListeningEnabled }) {
        self.managedDevicePolicy = managedDevicePolicy
        self.publishesPublicHostStatus = publishesPublicHostStatus
        self.pairingEnabled = pairingEnabled
    }

    var isNetworkingAllowed: Bool {
        pairingEnabled()
            && !managedDevicePolicy.isEnforced(.disableIrohNetworking)
            && !managedDevicePolicy.isEnforced(.disableRemoteControl)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        guard generationToken == token, wantsHost, isNetworkingAllowed,
              let activeScope, signingOutScope != activeScope else { return false }
        return auth?.isAuthenticatedTeamScopeCurrent(activeScope) == true
    }

    func listenerStateUpdates() -> AsyncStream<MobileHostListenerState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listenerContinuations[id] = continuation
            continuation.yield(listenerState)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.listenerContinuations.removeValue(forKey: id) }
            }
        }
    }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            await auth.awaitBootstrapped()
            for await scope in auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                if let scope, scope != self?.signingOutScope { self?.wantsHost = true }
                await self?.reconcile()
            }
        }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                guard !Task.isCancelled else { return }
                await self?.foreground()
            }
        }
    }

    func applyManagedNetworkingPolicy() async {
        wantsHost = true
        await reconcile()
    }

    func prepareForStop() {
        wantsHost = false
        requiresTransition = true
        admission?.invalidate()
        generationToken = UUID()
        listenerState = MobileHostListenerState()
    }

    func stopHost() async {
        prepareForStop()
        await transition(to: nil)
    }

    func beginSignOutPreparation() {
        signingOutScope = auth?.authenticatedTeamScope
        admission?.invalidate()
        generationToken = UUID()
        wantsHost = false
        let token = generationToken
        shutdownTask?.cancel()
        shutdownTask = Task { @MainActor [weak self] in
            guard let self, self.generationToken == token else { return }
            await self.stopHost()
        }
    }

    func foreground() async {
        await reconcile()
        guard isCurrent(generationToken) else { return }
        let token = generationToken
        await controlService?.foreground()
        guard isCurrent(token) else { return }
        await refreshListenerState(token: token)
        requestEndpointReady(token: token)
    }

    func restartForConfigurationChange() async {
        guard wantsHost, isNetworkingAllowed else { return }
        await transition(to: auth?.authenticatedTeamScope)
    }

    #if DEBUG
    func setIrohDebugTransportVerificationMode(_ mode: CmxIrohTransportVerificationMode) async {
        let modeName: String
        switch mode {
        case .automatic: modeName = IrxPathMode.automatic.rawValue
        case .relayOnly: modeName = IrxPathMode.relayOnly.rawValue
        case .directOnly: modeName = IrxPathMode.directOnly.rawValue
        }
        UserDefaults.standard.set(modeName, forKey: Self.pathModeDefaultsKey)
        await restartForConfigurationChange()
    }
    #endif

    private func reconcile() async {
        let scope = wantsHost && isNetworkingAllowed ? auth?.authenticatedTeamScope : nil
        let permitted = scope == signingOutScope ? nil : scope
        guard requiresTransition || permitted != activeScope || (permitted != nil && controlService == nil && activationTask == nil)
                || (permitted == nil && settingsPhase != .idle) else { return }
        await transition(to: permitted)
    }

    private func transition(to scope: AuthenticatedTeamScope?) async {
        requiresTransition = false
        generationToken = UUID()
        let token = generationToken
        activeScope = scope
        admission?.invalidate()
        let oldControl = controlService
        let oldEndpoint = endpointSupervisor
        let oldRegistry = registry
        activationTask?.cancel(); activationTask = nil
        controlTask?.cancel(); controlTask = nil
        endpointTask?.cancel(); endpointTask = nil
        permissionExpiryTask?.cancel(); permissionExpiryTask = nil
        acceptLoop?.cancel(); acceptLoop = nil
        admission = nil; registry = nil; identity = nil
        controlService = nil; endpointSupervisor = nil; cachedState = nil
        hadLiveDiscoveryThisRun = false
        setSettingsPhase(.idle)
        if publishesPublicHostStatus { MobileHostPublicStatusCache.update(irohIdentity: nil) }
        await oldControl?.stop()
        await oldRegistry?.closeAll(code: .hostShutdown)
        await oldEndpoint?.deactivate()
        guard generationToken == token, let scope, isCurrent(token) else { return }
        setSettingsPhase(.activating)
        activationTask = Task { @MainActor [weak self] in
            var failureCount = 0
            while !Task.isCancelled {
                guard let self, self.isCurrent(token) else { return }
                do {
                    try await self.provision(scope: scope, token: token)
                    return
                } catch {
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.setSettingsPhase(.failed)
                    Self.journal.record("v2-host", "setup-retry", ["error": String(describing: type(of: error))])
                    let delay = Self.activationRetryDelay(after: error, failureCount: failureCount, jitterUnitInterval: Double.random(in: 0...1))
                    failureCount += 1
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func setSettingsPhase(_ phase: SettingsPhase) {
        guard settingsPhase != phase else { return }
        settingsPhase = phase
        switch phase {
        case .idle: listenerState = MobileHostListenerState()
        case .activating: listenerState.phase = .starting
        case .failed: listenerState = MobileHostListenerState(phase: .retrying)
        case .active: break
        }
        publishIrxSettingsUpdate()
    }

    func noteLiveDiscoverySucceeded() { hadLiveDiscoveryThisRun = true }

    private func provision(scope: AuthenticatedTeamScope, token: UUID) async throws {
        guard isCurrent(token), let auth else { throw V2ControlFailure.stopped }
        let configuration = try MobileHostV2Configuration.current()
        let installation = MobileHostV2Installation(configuration: configuration)
        let deviceID = try await installation.deviceID()
        let tuple = V2Identity(appNamespace: configuration.namespace, buildTag: configuration.tag,
            deviceID: deviceID, environment: configuration.environment, projectID: configuration.projectID,
            teamID: scope.teamID, userID: scope.session.accountID)
        let key = try await installation.key(identity: tuple)
        let store = V2FileStateStore(rootDirectory: configuration.stateDirectory, fileManager: FileManager())
        let restored = try await store.load(identity: tuple)
        guard isCurrent(token), !Task.isCancelled else { throw V2ControlFailure.stopped }
        let device = V2DeviceDescriptor(endpointID: key.endpointID, identity: tuple,
            identityGeneration: restored?.device?.descriptor.identityGeneration ?? 1,
            metadata: V2DeviceMetadata(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                capabilities: ["irx-v2"], displayName: Host.current().localizedName ?? "Mac",
                pairingEnabled: true, platform: .mac, relayURLs: []))
        let identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: deviceID, appInstanceID: key.endpointID)
        let preferredPort = MobileHostService.configuredPort()
        let supervisor = IrxEndpointSupervisor(configuration: .init(identity: identity, pathMode: Self.pathMode,
            preferredBindAddress: "0.0.0.0:\(preferredPort)",
            initialRemoteBiStreams: 1, initialRemoteUniStreams: 0), journal: Self.journal)
        let admission = try V2InboundAdmissionAuthority(host: device)
        if let restored { _ = admission.restore(restored) }
        let http = V2URLSessionHTTPTransport(session: .shared)
        let dependencies = V2ControlDependencies(
            connect: { V2URLSessionSocket(session: .shared, request: $0) },
            http: { try await http.send($0) },
            stackAccessToken: { force in
                try await Self.accessToken(auth: auth, scope: scope, force: force)
            },
            sign: { data in
                guard await auth.isAuthenticatedTeamScopeCurrent(scope) else { throw V2ControlFailure.scopeMismatch }
                return try key.sign(data)
            })
        let service = V2ControlService(configuration: try .init(baseURL: configuration.baseURL, device: device),
            dependencies: dependencies, store: store)
        listenerState.preferredPort = preferredPort
        self.identity = identity
        self.admission = admission
        registry = IrxServerSessionRegistry(journal: Self.journal)
        endpointSupervisor = supervisor
        cachedState = restored ?? V2CachedState(identity: tuple)
        controlService = service
        if publishesPublicHostStatus { MobileHostPublicStatusCache.updateV2DeviceID(deviceID) }
        schedulePermissionExpiry(token: token)
        // A returning Mac listens using its cache while control setup runs independently.
        requestEndpointReady(token: token)
        controlTask = Task { @MainActor [weak self] in
            for await snapshot in await service.events() {
                guard !Task.isCancelled else { return }
                await self?.apply(snapshot, token: token)
            }
        }
        await service.start()
        guard isCurrent(token), !Task.isCancelled else { await service.stop(); throw V2ControlFailure.stopped }
        Self.journal.record("v2-host", "control-started", ["cached": String(restored != nil)])
    }

    private static func accessToken(auth: AuthCoordinator, scope: AuthenticatedTeamScope, force: Bool) async throws -> String {
        guard auth.isAuthenticatedTeamScopeCurrent(scope) else { throw V2ControlFailure.scopeMismatch }
        let token: String
        if force { token = try await auth.forceRefreshAccessToken() }
        else { token = try await auth.authenticatedSessionSnapshot().accessToken }
        guard auth.isAuthenticatedTeamScopeCurrent(scope) else { throw V2ControlFailure.scopeMismatch }
        return token
    }

    private func apply(_ snapshot: V2ControlSnapshot, token: UUID) async {
        guard isCurrent(token), let admission else { return }
        // The service publishes an empty initial observation before loading disk.
        guard snapshot.cache.device != nil || cachedState?.device == nil || snapshot.cache.authorityRevoked else { return }
        let previousCredentials = cachedState?.relayCredentials
        cachedState = snapshot.cache
        _ = admission.apply(snapshot)
        if snapshot.cache.authorityRevoked {
            admission.invalidate()
            endpointTask?.cancel(); endpointTask = nil
            permissionExpiryTask?.cancel(); permissionExpiryTask = nil
            await registry?.closeAll(code: .revoked)
            await endpointSupervisor?.deactivate()
            guard isCurrent(token) else { return }
            setSettingsPhase(.failed)
            return
        }
        if snapshot.status == .ready, snapshot.cache.directory != nil { noteLiveDiscoverySucceeded() }
        await registry?.closeAll(code: .revoked, matching: { admission.authorizedPeer(endpointID: $0) == nil })
        guard isCurrent(token) else { return }
        schedulePermissionExpiry(token: token)
        // Installing credentials does not replace the endpoint or its admitted sessions.
        if previousCredentials != snapshot.cache.relayCredentials, let supervisor = endpointSupervisor {
            await supervisor.rotateCredentials(Self.credentials(snapshot.cache))
            guard isCurrent(token) else { return }
        }
        requestEndpointReady(token: token)
        publishIrxSettingsUpdate()
    }

    private static func credentials(_ cache: V2CachedState) -> [IrxRelayCredential] {
        cache.relayCredentials.map { IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
            expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
            refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter))) }
    }

    private func requestEndpointReady(token: UUID) {
        guard isCurrent(token), endpointTask == nil, let supervisor = endpointSupervisor,
              let cache = cachedState, !cache.authorityRevoked,
              Self.pathMode == .directOnly || Self.credentials(cache).contains(where: { $0.isUsable(at: Date()) }) else { return }
        endpointTask = Task { @MainActor [weak self] in
            defer { if self?.generationToken == token { self?.endpointTask = nil } }
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isCurrent(token), let cache = self.cachedState, !cache.authorityRevoked else { return }
                do {
                    _ = try await supervisor.readyEndpoint(credentials: Self.credentials(cache))
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    await self.refreshListenerState(token: token)
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.startAcceptLoop(token: token)
                    self.setSettingsPhase(.active)
                    Self.journal.record("v2-host", "endpoint-ready", ["generation": String(await supervisor.currentGeneration)])
                    return
                } catch {
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.listenerState.phase = .retrying
                    self.listenerState.boundPort = nil
                    self.listenerState.localSocketAddresses = []
                    let delay = Self.activationRetryDelay(after: error, failureCount: failures, jitterUnitInterval: Double.random(in: 0...1))
                    failures += 1
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    private func schedulePermissionExpiry(token: UUID) {
        permissionExpiryTask?.cancel()
        guard let admission, let registry else { return }
        permissionExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let deadline = admission.nextExpiration {
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                await registry.closeAll(code: .revoked, matching: { admission.authorizedPeer(endpointID: $0) == nil })
            }
        }
    }

    private func refreshListenerState(token: UUID) async {
        guard isCurrent(token), let supervisor = endpointSupervisor else { return }
        let healthy = await supervisor.isHealthy()
        let port = await supervisor.boundPort()
        let addresses = await supervisor.localDirectAddresses()
        let relayURL = await supervisor.homeRelayURL()
        guard isCurrent(token), !Task.isCancelled else { return }
        var next = listenerState
        next.phase = healthy ? .ready : .starting
        next.boundPort = healthy ? port : nil
        next.localSocketAddresses = healthy ? addresses : []
        listenerState = next
        if healthy { publishRoute(relayURL: relayURL) }
        else if publishesPublicHostStatus { MobileHostPublicStatusCache.update(irohIdentity: nil) }
    }

    private func publishRoute(relayURL: String?) {
        guard publishesPublicHostStatus, let identity,
              let peer = try? CmxIrohPeerIdentity(endpointID: identity.endpointIDHex) else { return }
        let now = Date()
        let expiry = cachedState?.relayCredentials.filter { $0.relayURL == relayURL }.map {
            Date(timeIntervalSince1970: Double($0.expiresAt))
        }.max()
        let hints: [CmxIrohPathHint] = relayURL.flatMap { relay in
            guard let expiry, expiry > now else { return nil }
            return try? CmxIrohPathHint(kind: .relayURL, value: relay, source: .native,
                privacyScope: .publicInternet, observedAt: now, expiresAt: expiry)
        }.map { [$0] } ?? []
        MobileHostPublicStatusCache.update(irohIdentity: peer, pathHints: hints)
    }

    private func startAcceptLoop(token: UUID) {
        guard acceptLoop == nil, let supervisor = endpointSupervisor, let registry, let admission else { return }
        acceptLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCurrent(token) else { return }
                guard let inbound = await supervisor.acceptNextInbound() else {
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.acceptLoop = nil
                    await self.refreshListenerState(token: token)
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.requestEndpointReady(token: token)
                    return
                }
                guard self.isCurrent(token), !Task.isCancelled else {
                    if case .irx(let connection) = inbound { await connection.close(code: .hostShutdown, origin: .local) }
                    return
                }
                switch inbound {
                case .irx(let connection):
                    Task { [weak self] in
                        await self?.superviseConnection(connection, judge: admission, registry: registry, token: token)
                    }
                case .foreign(_, let connection):
                    try? connection.close(errorCode: 1, reason: Data("unsupported_alpn".utf8))
                }
            }
        }
    }

    private func superviseConnection(
        _ irx: IrxConnection,
        judge: V2InboundAdmissionAuthority,
        registry: IrxServerSessionRegistry,
        token: UUID
    ) async {
        let journal = Self.journal
        guard
            let (peer, control, sessionID) = await IrxAdmission.performServer(
                connection: irx,
                judgment: judge.judgment(),
                journal: journal
            )
        else { return }
        let registered = await registry.admit(
            deviceID: peer.bindingID,
            sessionID: sessionID,
            connection: irx,
            stillAuthorized: judge.recheck(peer)
        )
        guard registered, isCurrent(token) else {
            await irx.close(code: .revoked, origin: .local)
            return
        }
        // Automatic path mode: authorize NAT traversal so the admitted session
        // can upgrade to a direct/LAN path make-before-break.
        if !Self.forceRelayOnly {
            await irx.authorizeDirectPaths()
        }

        let admittedPeer: CmxIrohAdmittedPeer
        do {
            admittedPeer = CmxIrohAdmittedPeer(
                peer: CmxIrohGrantPeer(
                    bindingID: peer.bindingID,
                    deviceID: peer.deviceID,
                    tag: peer.tag,
                    platform: .ios,
                    endpointID: try CmxIrohPeerIdentity(endpointID: peer.endpointIDHex),
                    identityGeneration: peer.identityGeneration
                )
            )
        } catch {
            await irx.close(code: .identityMismatch, origin: .local)
            return
        }

        let artifactRegistry = MobileHostIrohArtifactTransferRegistry()
        let eventWriter = MobileHostIrxEventWriter(connection: irx, journal: journal)
        let laneLoop = Task {
            await Self.runLaneLoop(
                irx, admittedPeer: admittedPeer, artifactRegistry: artifactRegistry,
                journal: journal)
        }
        let controlTransport = IrxControlByteTransport(
            connection: irx, control: control, closeCode: .hostShutdown)
        let exit = await MobileHostService.acceptTransport(
            controlTransport,
            authorization: .irohAdmission(admittedPeer),
            artifactTransfers: artifactRegistry,
            independentEventWriter: eventWriter,
            // The bounded Iroh peer pool stays alive via transport keepalives.
            // Control-idle timeout is for unowned legacy TCP connections and
            // must not tear down a healthy multi-lane QUIC session.
            idleTimeoutNanoseconds: 0,
            isCurrent: { [weak self] in
                let runtime = self
                return await MainActor.run { runtime?.isCurrent(token) == true }
            }
        )
        journal.record(
            "host-runtime", "connection-exit",
            [
                "session": sessionID,
                "lifecycle": String(describing: exit.lifecycle),
                "failure": String(describing: exit.failure),
            ]
        )
        laneLoop.cancel()
        await eventWriter.close()
        await irx.close(code: .hostShutdown, origin: .local)
        await registry.remove(deviceID: peer.bindingID, sessionID: sessionID)
    }

    /// Post-admission lane dispatch: keepalive echo, terminal streams over
    /// the byte tee, artifact reads. Quotas mirror the legacy router.
    private nonisolated static func runLaneLoop(
        _ irx: IrxConnection,
        admittedPeer: CmxIrohAdmittedPeer,
        artifactRegistry: MobileHostIrohArtifactTransferRegistry,
        journal: IrxJournal
    ) async {
        let terminalLaneQuota = MobileHostIrxTerminalLaneQuota()
        while !Task.isCancelled {
            guard let lane = await irx.acceptLane() else { return }
            journal.record(
                "host-lanes", "lane-accepted",
                [
                    "lane": lane.descriptor.lane.rawValue,
                    "resource": lane.descriptor.resource ?? "-",
                ]
            )
            switch lane.descriptor.lane {
            case .keepalive:
                _ = irx.respondKeepalive(on: lane)
            case .terminal:
                guard await terminalLaneQuota.reserve() else {
                    await lane.writer.reset(errorCode: 3)
                    await lane.reader.stop(errorCode: 3)
                    continue
                }
                let resource = lane.descriptor.resource ?? ""
                let cursor = lane.descriptor.cursor
                Task {
                    await MobileHostIrxTerminalLaneServer.serve(
                        resourceID: resource,
                        cursor: cursor,
                        stream: lane.bidirectional(),
                        journal: journal
                    )
                    await terminalLaneQuota.release()
                }
            case .terminalInput:
                guard await terminalLaneQuota.reserve() else {
                    await lane.writer.reset(errorCode: 3)
                    await lane.reader.stop(errorCode: 3)
                    continue
                }
                let resource = lane.descriptor.resource ?? ""
                Task {
                    await MobileHostIrxTerminalLaneServer.serveInputOnly(
                        resourceID: resource,
                        stream: lane.bidirectional(),
                        journal: journal
                    )
                    await terminalLaneQuota.release()
                }
            case .artifact:
                guard let resource = try? CmxIrohResourceID(lane.descriptor.resource ?? "")
                else {
                    await lane.writer.reset(errorCode: 2)
                    await lane.reader.stop(errorCode: 2)
                    continue
                }
                let offset = lane.descriptor.offset ?? 0
                Task {
                    let handler = MobileHostIrohArtifactLaneHandler(registry: artifactRegistry)
                    _ = await handler.handleArtifactLane(
                        resourceID: resource,
                        offset: offset,
                        stream: lane.bidirectional(),
                        peer: admittedPeer
                    )
                }
            case .simulatorStream:
                guard let resource = try? CmxIrohResourceID(lane.descriptor.resource ?? "")
                else {
                    await lane.writer.reset(errorCode: 2)
                    await lane.reader.stop(errorCode: 2)
                    continue
                }
                // No lane count here: the v2 stream coordinator enforces
                // last-writer-wins per panel, so a new attach supersedes and
                // closes the previous session's lane.
                Task {
                    let stream = lane.bidirectional()
                    let handler = MobileHostIrohSimulatorStreamLaneHandler()
                    let didTakeOwnership = await handler.handleSimulatorStreamLane(
                        resourceID: resource,
                        stream: stream,
                        peer: admittedPeer
                    )
                    if !didTakeOwnership {
                        await stream.sendStream.reset(errorCode: 2)
                        await stream.receiveStream.stop(errorCode: 2)
                    }
                }
            case .control, .events:
                // control arrives only pre-admission; events is server-opened.
                await lane.writer.reset(errorCode: 2)
                await lane.reader.stop(errorCode: 2)
            }
        }
    }
}

/// Tracks active IRX terminal lanes rather than cumulative opens. Replay
/// barriers intentionally close and reopen lanes, so a connection must return
/// its credit when a serving task finishes or the fast input lane eventually
/// becomes permanently unavailable after four reopen cycles.
private actor MobileHostIrxTerminalLaneQuota {
    private static let maximum = 4
    private var activeCount = 0

    func reserve() -> Bool {
        guard activeCount < Self.maximum else { return false }
        activeCount += 1
        return true
    }

    func release() {
        activeCount = max(0, activeCount - 1)
    }
}

/// Server-events lane writer over irx: opened lazily at priority 50, reset on
/// stall so the host service can renegotiate, mirroring the legacy contract.
actor MobileHostIrxEventWriter: MobileHostIndependentEventWriting {
    private let connection: IrxConnection
    private let journal: IrxJournal
    private var writer: IrxStreamWriter?

    init(connection: IrxConnection, journal: IrxJournal) {
        self.connection = connection
        self.journal = journal
    }

    func probe(_ framedData: Data) async -> Bool {
        do {
            try await send(framedData)
            return true
        } catch {
            return false
        }
    }

    func send(_ framedData: Data) async throws {
        let writer = try await openedWriter()
        try await writer.write(framedData)
    }

    func reset() async {
        if let writer {
            await writer.finish()
        }
        writer = nil
        journal.record("host-events", "writer-reset")
    }

    func close() async {
        if let writer {
            await writer.finish()
        }
        writer = nil
    }

    private func openedWriter() async throws -> IrxStreamWriter {
        if let writer { return writer }
        let opened = try await connection.openUniLane(IrxLaneDescriptor(lane: .events))
        try? await opened.setPriority(50)
        writer = opened
        journal.record("host-events", "writer-opened")
        return opened
    }
}

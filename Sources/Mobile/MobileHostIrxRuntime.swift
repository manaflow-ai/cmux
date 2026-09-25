import CmuxCloud
import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxSettings
import Foundation
import IrohLib
import OSLog

private final class MobileHostV2RelayAddressCallback: AddrChangeCallback, Sendable {
    private let handler: @Sendable () async -> Void

    init(handler: @escaping @Sendable () async -> Void) { self.handler = handler }

    func onChange(addr: EndpointAddr) async throws { await handler() }
}

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

    private nonisolated static var hostReleaseTrack: String {
        #if DEBUG
        return "dev"
        #else
        return (Bundle.main.bundleIdentifier ?? "").contains("nightly") ? "nightly" : "stable"
        #endif
    }

    enum SettingsPhase: Equatable { case idle, activating, active, failed }
    private let managedDevicePolicy: ManagedDevicePolicy
    private let pairingEnabled: @MainActor () -> Bool
    private let publishesPublicHostStatus: Bool
    private(set) weak var auth: AuthCoordinator?
    weak var outgoingDeviceClient: DeviceIrxClient?
    /// Native layout synchronization is instantiated only for admitted Mac peers.
    private lazy var deviceWorkspaceLayouts = DeviceWorkspaceLayoutHost(
        capture: { Workspace.liveWorkspace(id: $0)?.deviceWorkspaceLayoutSnapshot() },
        apply: { id, layout in
            guard let workspace = Workspace.liveWorkspace(id: id) else { throw DeviceLinkError.notConnected }
            try workspace.applyDeviceWorkspaceLayout(layout)
        },
        createTerminal: { id, source, direction in
            Workspace.liveWorkspace(id: id)?.createDeviceWorkspaceTerminal(near: source, direction: direction)
        },
        publish: { snapshot in
            guard let data = try? JSONEncoder().encode(snapshot),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            MobileHostService.emitEvent(topic: DeviceWorkspaceLayoutHost.eventTopic, payload: payload)
        }
    )
    private var activePairingEnabled: Bool?
    private var activeDeviceCapabilities: [String] = []
    private var deviceMetadataTask: Task<Void, Never>?
    private var authObservationTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var activeScope: AuthenticatedTeamScope?
    private var signingOutScope: AuthenticatedTeamScope?
    private var wantsHost = true
    private var requiresTransition = false
    private(set) var generationToken = UUID()
    private(set) var activationTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    private var endpointRefreshPending = false
    private var relayAddressWatch: WatchHandle?
    private var relayAddressWatchGeneration: Int?
    private var permissionExpiryTask: Task<Void, Never>?
    private var acceptLoop: Task<Void, Never>?
    private var lastLoggedControlState: String?
    private var admission: V2InboundAdmissionAuthority?
    /// Compatibility publication for older iOS dialects. It shares the v2
    /// signing key but has its own filtered authority and broker lifecycle.
    private var legacyService: LegacyCompatibilityService?
    private var legacyAcceptorPeer: CmxIrohGrantPeer?
    private var legacyStartTask: Task<Void, Never>?
    private var legacyEventsTask: Task<Void, Never>?
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
    /// Safe native relay diagnosis, retained through retries until recovery.
    private(set) var relayFailureDescription: String?
    private(set) var hadLiveDiscoveryThisRun = false
    var irxSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var irxSettingsRefreshTask: Task<Void, Never>?

    init(managedDevicePolicy: ManagedDevicePolicy = ManagedDevicePolicy(), publishesPublicHostStatus: Bool = false,
         pairingEnabled: @escaping @MainActor () -> Bool = { MobileHostService.isListeningEnabled }) {
        self.managedDevicePolicy = managedDevicePolicy
        self.publishesPublicHostStatus = publishesPublicHostStatus
        self.pairingEnabled = pairingEnabled
    }

    /// Projects the two Mac-only capabilities independently. Incoming access
    /// must never implicitly advertise outbound Mac discovery: iOS pairing and
    /// Mac hosting share this endpoint but are separate authorization routes.
    nonisolated static func macDeviceCapabilities(
        discoveryEnabled: Bool,
        incomingAccessEnabled: Bool
    ) -> [String] {
        var result: [String] = []
        if discoveryEnabled { result.append("cmux.mac-devices.v1") }
        if incomingAccessEnabled { result.append("cmux.mac-host.v1") }
        return result
    }

    /// Selects the independent admission policy after the peer has been
    /// authenticated by the IROH grant and TLS endpoint identity.
    nonisolated static func allowsInboundPeer(
        isMac: Bool,
        pairingEnabled: Bool,
        incomingAccessEnabled: Bool
    ) -> Bool {
        isMac ? incomingAccessEnabled : pairingEnabled
    }

    private var deviceCapabilities: [String] {
        Self.macDeviceCapabilities(
            discoveryEnabled: DevicesFeature.isEnabled,
            incomingAccessEnabled: MobileRemoteControlPolicy.allowsIncomingAccess()
        )
    }

    /// ALPNs the single v2 endpoint serves beside irx. Shipped iOS builds dial
    /// the legacy `cmux/mobile/1` dialect, so it rides the same endpoint
    /// instead of a separate listener.
    nonisolated static var endpointAdditionalALPNs: [Data] {
        [MobileHostIrxLegacyDialectServer.legacyALPN]
    }

    /// Whether an inbound connection on `alpn` is handed to the legacy dialect
    /// server. It follows the same pairing opt-in as the v2 runtime.
    func acceptsLegacyDialect(alpn: Data) -> Bool {
        pairingEnabled() && alpn == MobileHostIrxLegacyDialectServer.legacyALPN
    }

    var isNetworkingAllowed: Bool {
        (pairingEnabled() || DevicesFeature.isEnabled || MobileRemoteControlPolicy.allowsIncomingAccess())
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
        if publishesPublicHostStatus { MobileHostPublicStatusCache.removeAll() }
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
        listenerState = MobileHostListenerState()
        if publishesPublicHostStatus { MobileHostPublicStatusCache.removeAll() }
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
        // Discoverability is signed metadata on the existing endpoint. A host
        // toggle must not retire this Mac's independent outgoing device sessions.
        if !requiresTransition, permitted != nil, permitted == activeScope,
           (activePairingEnabled == pairingEnabled() || activeDeviceCapabilities != deviceCapabilities),
           controlService != nil {
            if activeDeviceCapabilities != deviceCapabilities {
                await enforcePeerPermissions(token: generationToken)
                updateDeviceHostingMetadata()
            }
            return
        }
        guard requiresTransition || permitted != activeScope
                || activePairingEnabled != pairingEnabled() || activeDeviceCapabilities != deviceCapabilities || (permitted != nil && controlService == nil && activationTask == nil)
                || (permitted == nil && settingsPhase != .idle) else { return }
        await transition(to: permitted)
    }

    private func updateDeviceHostingMetadata() {
        guard deviceMetadataTask == nil, let service = controlService else { return }
        let token = generationToken
        deviceMetadataTask = Task { @MainActor [weak self] in
            defer {
                if self?.generationToken == token { self?.deviceMetadataTask = nil }
            }
            while let self, self.isCurrent(token), !Task.isCancelled,
                  (self.activeDeviceCapabilities != self.deviceCapabilities || self.activePairingEnabled != self.pairingEnabled()) {
                let capabilities = self.deviceCapabilities
                let pairing = self.pairingEnabled()
                guard let metadata = await service.snapshot().cache.device?.descriptor.metadata else { return }
                guard self.isCurrent(token), !Task.isCancelled else { return }
                let next = V2DeviceMetadata(appVersion: metadata.appVersion,
                    capabilities: metadata.capabilities.filter { !["cmux.mac-devices.v1", "cmux.mac-host.v1"].contains($0) } + capabilities,
                    displayName: metadata.displayName, pairingEnabled: pairing,
                    platform: metadata.platform, relayURLs: metadata.relayURLs)
                do {
                    try await service.updateMetadata(next)
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.activeDeviceCapabilities = capabilities
                    self.activePairingEnabled = pairing
                    await self.enforcePeerPermissions(token: token)
                } catch {
                    Self.journal.record("v2-host", "hosting-metadata-failed", ["error": String(describing: type(of: error))])
                    return
                }
            }
        }
    }

    private func transition(to scope: AuthenticatedTeamScope?) async {
        requiresTransition = false
        generationToken = UUID()
        let token = generationToken
        activeScope = scope
        activePairingEnabled = pairingEnabled()
        activeDeviceCapabilities = deviceCapabilities
        admission?.invalidate()
        let oldControl = controlService
        let oldEndpoint = endpointSupervisor
        let oldRegistry = registry
        let oldLegacy = legacyService
        let oldRelayWatch = relayAddressWatch
        deviceMetadataTask?.cancel(); deviceMetadataTask = nil
        activationTask?.cancel(); activationTask = nil
        controlTask?.cancel(); controlTask = nil
        endpointTask?.cancel(); endpointTask = nil
        endpointRefreshPending = false
        relayAddressWatch = nil; relayAddressWatchGeneration = nil
        permissionExpiryTask?.cancel(); permissionExpiryTask = nil
        acceptLoop?.cancel(); acceptLoop = nil
        admission = nil; registry = nil; identity = nil
        legacyService = nil
        legacyAcceptorPeer = nil
        legacyStartTask?.cancel(); legacyStartTask = nil
        legacyEventsTask?.cancel(); legacyEventsTask = nil
        controlService = nil; endpointSupervisor = nil; cachedState = nil
        lastLoggedControlState = nil
        hadLiveDiscoveryThisRun = false
        setSettingsPhase(.idle)
        if publishesPublicHostStatus { MobileHostPublicStatusCache.removeAll() }
        await outgoingDeviceClient?.enforce(nil)
        if let oldControl, let metadata = await oldControl.snapshot().cache.device?.descriptor.metadata,
           metadata.pairingEnabled || metadata.capabilities.contains("cmux.mac-host.v1"), scope == nil || !pairingEnabled() {
            let withdrawn = V2DeviceMetadata(appVersion: metadata.appVersion,
                capabilities: metadata.capabilities.filter { $0 != "cmux.mac-host.v1" },
                displayName: metadata.displayName, pairingEnabled: false, platform: .mac, relayURLs: [])
            try? await oldControl.updateMetadata(withdrawn)
        }
        await oldControl?.stop()
        await oldRelayWatch?.stop()
        await oldRegistry?.closeAll(code: .hostShutdown)
        await oldLegacy?.stop(revokeOwnBinding: true)
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
                    Self.journal.record("v2-host", "setup-retry", [
                        "error": (error as? V2ControlFailure)?.diagnosticCode ?? String(describing: type(of: error))
                    ])
                    let delay = Self.activationRetryDelay(after: error, failureCount: failureCount, jitterUnitInterval: Double.random(in: 0...1))
                    failureCount += 1
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func setSettingsPhase(_ phase: SettingsPhase, error: (any Error)? = nil) {
        let nextFailure: String?
        if phase == .idle || phase == .active {
            nextFailure = nil
        } else if let error {
            nextFailure = (error as? IrxEndpointError)?.errorDescription
        } else {
            // Activation retries briefly re-enter .activating and .failed
            // without a new endpoint error. Keep the last safe diagnosis
            // visible until the endpoint recovers or the scope is reset.
            nextFailure = relayFailureDescription
        }
        guard settingsPhase != phase || nextFailure != relayFailureDescription else { return }
        settingsPhase = phase
        relayFailureDescription = nextFailure
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
        let store = V2FileStateStore(rootDirectory: configuration.stateDirectory, fileManager: FileManager(), identityKey: key)
        let restored = try await store.load(identity: tuple)
        guard isCurrent(token), !Task.isCancelled else { throw V2ControlFailure.stopped }
        let device = V2DeviceDescriptor(endpointID: key.endpointID, identity: tuple,
            identityGeneration: restored?.device?.descriptor.identityGeneration ?? 1,
            metadata: V2DeviceMetadata(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                capabilities: ["irx-v2"] + deviceCapabilities, displayName: Host.current().localizedName ?? "Mac",
                pairingEnabled: pairingEnabled(), platform: .mac,
                relayURLs: restored?.device?.descriptor.metadata.relayURLs ?? []))
        let identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: deviceID, appInstanceID: key.endpointID)
        let preferredPort = MobileHostService.configuredPort()
        let supervisor = IrxEndpointSupervisor(configuration: .init(identity: identity, pathMode: Self.pathMode,
            preferredBindAddress: "0.0.0.0:\(preferredPort)",
            initialRemoteBiStreams: 1, initialRemoteUniStreams: 0,
            additionalALPNs: Self.endpointAdditionalALPNs), journal: Self.journal)
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
        if pairingEnabled(), let namespace = CmxIrohMacBundleNamespace(bundleIdentifier: Bundle.main.bundleIdentifier),
           let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL {
            let compatibility = try LegacyCompatibilityService(
                configuration: .init(
                    brokerBaseURL: brokerBaseURL,
                    controlSocketURL: PresenceHeartbeatClient.resolvedServiceURL(),
                    clientNamespace: namespace.rawValue,
                    tag: configuration.tag,
                    platform: .mac,
                    displayName: device.metadata.displayName,
                    cacheDirectory: configuration.stateDirectory.appendingPathComponent("legacy-compat", isDirectory: true)
                        .appendingPathComponent(identity.endpointIDHex, isDirectory: true),
                    accountID: scope.session.accountID,
                    identityGeneration: device.identityGeneration,
                    appVersion: device.metadata.appVersion,
                    releaseTrack: Self.hostReleaseTrack),
                identity: LegacyCompatibilityService.compatibilityIdentity(
                    from: identity, deviceID: MobileHostIdentity.deviceID()),
                previousDeviceID: LegacyCompatibilityService.compatibilityIdentity(from: identity).deviceID,
                accessTokenPair: { [weak auth] in
                    guard let auth else { return nil }
                    guard await auth.isAuthenticatedTeamScopeCurrent(scope) else { return nil }
                    let snapshot = try await auth.authenticatedSessionSnapshot()
                    guard await auth.isAuthenticatedTeamScopeCurrent(scope) else { return nil }
                    return (access: snapshot.accessToken, refresh: snapshot.refreshToken)
                }, journal: Self.journal)
            self.legacyService = compatibility
        }
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
        let status = String(describing: snapshot.status)
        let failure = snapshot.failure?.diagnosticCode ?? "none"
        let state = status + ":" + failure
        if state != lastLoggedControlState {
            lastLoggedControlState = state
            Self.journal.record("v2-control", "state-changed", ["status": status, "failure": failure,
                "environment": snapshot.cache.identity.environment,
                "project": snapshot.cache.identity.projectID])
        }
        // The service publishes an empty initial observation before loading disk.
        guard snapshot.cache.device != nil || cachedState?.device == nil || snapshot.cache.authorityRevoked else { return }
        let previousCredentials = cachedState?.relayCredentials
        cachedState = snapshot.cache
        _ = admission.apply(snapshot)
        await outgoingDeviceClient?.enforce(snapshot.cache)
        guard isCurrent(token) else { return }
        if let legacyService {
            let modernEndpoints = Set((snapshot.cache.directory?.inboundPeers ?? []).map {
                $0.device.descriptor.endpointID
            }).union((snapshot.cache.directory?.devices ?? []).map { $0.descriptor.endpointID })
            await legacyService.excludeV2Endpoints(modernEndpoints)
            guard isCurrent(token), !Task.isCancelled else { return }
        }
        if snapshot.cache.authorityRevoked {
            admission.invalidate()
            let oldLegacy = legacyService
            legacyService = nil
            legacyAcceptorPeer = nil
            legacyStartTask?.cancel(); legacyStartTask = nil
            legacyEventsTask?.cancel(); legacyEventsTask = nil
            endpointTask?.cancel(); endpointTask = nil
            endpointRefreshPending = false
            let oldRelayWatch = relayAddressWatch
            let oldRegistry = registry
            let oldEndpoint = endpointSupervisor
            relayAddressWatch = nil; relayAddressWatchGeneration = nil
            permissionExpiryTask?.cancel(); permissionExpiryTask = nil
            await oldRegistry?.closeAll(code: .revoked)
            await oldEndpoint?.deactivate()
            await oldRelayWatch?.stop()
            await oldLegacy?.stop(revokeOwnBinding: true)
            guard isCurrent(token) else { return }
            setSettingsPhase(.failed)
            return
        }
        if snapshot.status == .ready, let record = snapshot.cache.device,
           !record.revoked, record.descriptor.identity == snapshot.cache.identity,
           record.descriptor.endpointID == identity?.endpointIDHex {
            listenerState.hasAuthenticatedRegistration = true
            if snapshot.cache.directory != nil { noteLiveDiscoverySucceeded() }
            startLegacyCompatibility(token: token)
        }
        await enforcePeerPermissions(token: token)
        guard isCurrent(token) else { return }
        schedulePermissionExpiry(token: token)
        // Installing credentials does not replace the endpoint or its admitted sessions.
        if previousCredentials != snapshot.cache.relayCredentials, let supervisor = endpointSupervisor {
            await supervisor.rotateCredentials(Self.credentials(snapshot.cache))
            guard isCurrent(token) else { return }
        }
        requestEndpointReady(token: token)
        if activeDeviceCapabilities != deviceCapabilities { updateDeviceHostingMetadata() }
        publishIrxSettingsUpdate()
    }

    private func startLegacyCompatibility(token: UUID) {
        guard isCurrent(token), pairingEnabled(), legacyStartTask == nil, legacyAcceptorPeer == nil,
              let service = legacyService, let identity,
              let configuration = try? MobileHostV2Configuration.current() else { return }
        legacyStartTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.generationToken == token { self.legacyStartTask = nil }
            }
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isCurrent(token), self.legacyService === service else { return }
                do {
                    try await service.start()
                    let snapshot = await service.snapshot()
                    guard self.isCurrent(token), !Task.isCancelled,
                          self.legacyService === service, !snapshot.stopped,
                          let binding = snapshot.binding,
                          let endpointID = try? CmxIrohPeerIdentity(endpointID: identity.endpointIDHex) else { return }
                    self.legacyAcceptorPeer = CmxIrohGrantPeer(bindingID: binding.bindingID,
                        deviceID: binding.deviceID, tag: binding.tag,
                        platform: .mac, endpointID: endpointID,
                        identityGeneration: binding.identityGeneration)
                    self.legacyEventsTask?.cancel()
                    self.legacyEventsTask = Task { @MainActor [weak self] in
                        for await _ in await service.events() {
                            guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                            await self.enforcePeerPermissions(token: token)
                            guard self.isCurrent(token), !Task.isCancelled else { return }
                            self.schedulePermissionExpiry(token: token)
                        }
                    }
                    await self.publishHomeRelayHintIfNeeded(token: token)
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    Self.journal.record("legacy-dialect", "compatibility-started", ["tag": configuration.tag])
                    return
                } catch {
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    Self.journal.record("legacy-dialect", "compatibility-start-failed",
                        ["error": String(describing: type(of: error))])
                    if let brokerError = error as? CmxIrohTrustBrokerClientError {
                        switch brokerError {
                        case .rejected(let status, _), .rejectedWithRetryAfter(let status, _, _):
                            guard status == 408 || status == 425 || status == 429 || (500...599).contains(status) else { return }
                        case .missingAuthentication, .invalidAuthentication, .invalidBaseURL,
                             .nonHTTPResponse, .invalidResponse:
                            return
                        default: break
                        }
                    }
                    let delay = Self.activationRetryDelay(after: error, failureCount: failures,
                        jitterUnitInterval: Double.random(in: 0...1))
                    failures += 1
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
            }
        }
    }

    private static func credentials(_ cache: V2CachedState) -> [IrxRelayCredential] {
        cache.relayCredentials.map { IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
            expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
            refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter))) }
    }

    private func requestEndpointReady(token: UUID) {
        guard isCurrent(token) else { return }
        guard endpointTask == nil else { endpointRefreshPending = true; return }
        guard let supervisor = endpointSupervisor,
              let cache = cachedState, !cache.authorityRevoked,
              Self.pathMode == .directOnly || Self.credentials(cache).contains(where: { $0.isUsable(at: Date()) }) else { return }
        endpointTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.generationToken == token {
                    self.endpointTask = nil
                    if self.endpointRefreshPending {
                        self.endpointRefreshPending = false
                        self.requestEndpointReady(token: token)
                    }
                }
            }
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isCurrent(token), let cache = self.cachedState, !cache.authorityRevoked else { return }
                do {
                    let endpoint = try await supervisor.readyEndpoint(credentials: Self.credentials(cache))
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    let endpointGeneration = await supervisor.currentGeneration
                    if self.relayAddressWatchGeneration != endpointGeneration {
                        await self.relayAddressWatch?.stop()
                        guard self.isCurrent(token), !Task.isCancelled else { return }
                        self.relayAddressWatchGeneration = endpointGeneration
                        self.relayAddressWatch = endpoint.watchAddr(callback: MobileHostV2RelayAddressCallback { [weak self] in
                            await self?.requestEndpointReady(token: token)
                        })
                    }
                    await self.refreshListenerState(token: token)
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.startAcceptLoop(token: token)
                    self.setSettingsPhase(.active)
                    Self.journal.record("v2-host", "endpoint-ready", ["generation": String(await supervisor.currentGeneration)])
                    await self.publishHomeRelayHintIfNeeded(token: token)
                    return
                } catch {
                    guard self.isCurrent(token), !Task.isCancelled else { return }
                    self.setSettingsPhase(.failed, error: error)
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

    /// Publish only the public relay location needed by peers to address this
    /// endpoint. Direct addresses stay local to the two clients.
    private func publishHomeRelayHintIfNeeded(token: UUID) async {
        guard isCurrent(token), let supervisor = endpointSupervisor else { return }
        let relay = await supervisor.homeRelayURL()
        guard isCurrent(token), let metadata = cachedState?.device?.descriptor.metadata else { return }
        if let legacyService {
            try? await legacyService.publishRelayHint(relay)
        }
        guard isCurrent(token), !Task.isCancelled, let relay,
              metadata.relayURLs != [relay], let service = controlService else { return }
        let next = V2DeviceMetadata(
            appVersion: metadata.appVersion,
            capabilities: metadata.capabilities.filter { !["cmux.mac-devices.v1", "cmux.mac-host.v1"].contains($0) } + deviceCapabilities,
            displayName: metadata.displayName,
            pairingEnabled: metadata.pairingEnabled,
            platform: metadata.platform,
            relayURLs: [relay]
        )
        do {
            try await service.updateMetadata(next)
            guard isCurrent(token) else { return }
            Self.journal.record("v2-host", "home-relay-published", ["relay": relay])
        } catch {
            guard isCurrent(token) else { return }
            Self.journal.record("v2-host", "home-relay-publish-failed", ["error": String(describing: type(of: error))])
        }
    }

    private func enforcePeerPermissions(token: UUID) async {
        guard isCurrent(token), let admission, let registry else { return }
        let legacyCurrent = legacyService?.listCurrent
        let macEndpoints = Set(cachedState?.directory?.inboundPeers?.filter {
            $0.device.descriptor.metadata.platform == .mac
        }.map { $0.device.descriptor.endpointID } ?? [])
        let allowsMacAccess = MobileRemoteControlPolicy.allowsIncomingAccess()
        await registry.closeAll(code: .revoked, matching: { endpoint in
            if !allowsMacAccess, macEndpoints.contains(endpoint) { return true }
            if let list = legacyCurrent?.current, let entry = list.entries[endpoint] {
                return !list.isFresh(now: .now) || entry.revoked
                    || entry.capabilities?.contains(LegacyCompatibilityService.v2Capability) == true
            }
            return admission.authorizedPeer(endpointID: endpoint) == nil
        })
    }

    private func schedulePermissionExpiry(token: UUID) {
        permissionExpiryTask?.cancel()
        guard isCurrent(token), let admission else { return }
        let legacyCurrent = legacyService?.listCurrent
        permissionExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCurrent(token) else { return }
                await self.enforcePeerPermissions(token: token)
                guard self.isCurrent(token), !Task.isCancelled else { return }
                let now = ContinuousClock().now
                let legacyDeadline = legacyCurrent?.current.map {
                    $0.receivedAtMonotonic.advanced(by: .seconds($0.ttlSeconds))
                }.flatMap { $0 > now ? $0 : nil }
                // An expired older-client list must not stop enforcement of
                // future v2 permission expiry, or reschedule an elapsed deadline.
                let deadline = [admission.nextExpiration, legacyDeadline].compactMap { $0 }.min()
                guard let deadline else { return }
                do { try await ContinuousClock().sleep(until: deadline) }
                catch { return }
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
        let legacyCurrent = legacyService?.listCurrent
        let v2Judgment = admission.judgment()
        let legacyJudgment = legacyCurrent.map { IrxListJudge(current: $0, journal: Self.journal).judgment() }
        let judgment: IrxGrantJudgment = { grant, endpoint in
            // A current legacy entry is authoritative for old peers. Modern
            // endpoints are excluded from that list, so they can only pass the
            // independent v2 authority and never gain legacy fallback.
            if let legacyCurrent, legacyCurrent.current?.entries[endpoint] != nil,
               let legacyJudgment {
                return try legacyJudgment(grant, endpoint)
            }
            return try v2Judgment(grant, endpoint)
        }
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
                        await self?.superviseConnection(connection, judgment: judgment,
                            admission: admission, legacyCurrent: legacyCurrent,
                            registry: registry, token: token)
                    }
                case .foreign(let alpn, let connection):
                    guard self.acceptsLegacyDialect(alpn: alpn),
                          let legacyService,
                          let trust = legacyService.broker.cachedTrustForAdmission(),
                          let acceptor = self.legacyAcceptor(token: token) else {
                        try? connection.close(errorCode: 1, reason: Data("unsupported_alpn".utf8))
                        continue
                    }
                    let adopted = try? CmxIrohLibEndpointFactory.adoptAcceptedConnection(connection)
                    guard let adopted else { continue }
                    Task {
                        await MobileHostIrxLegacyDialectServer.serve(adopted: adopted,
                            acceptor: acceptor, trust: trust,
                            brokerClient: legacyService.broker.hostBrokerClient,
                            listCurrent: legacyService.listCurrent,
                            isCurrent: { [weak self] in
                                guard let self else { return false }
                                return await MainActor.run { self.isCurrent(token) }
                            }, journal: Self.journal)
                    }
                }
            }
        }
    }

    private func legacyAcceptor(token: UUID) -> CmxIrohGrantPeer? {
        guard isCurrent(token) else { return nil }
        return legacyAcceptorPeer
    }

    private func superviseConnection(
        _ irx: IrxConnection,
        judgment: @escaping IrxGrantJudgment,
        admission: V2InboundAdmissionAuthority,
        legacyCurrent: IrxDeviceListCurrent?,
        registry: IrxServerSessionRegistry,
        token: UUID
    ) async {
        let journal = Self.journal
        guard
            let (peer, control, sessionID) = await IrxAdmission().performServer(
                connection: irx,
                judgment: judgment,
                journal: journal
            )
        else { return }
        let isMac = cachedState?.directory?.inboundPeers?.first {
            $0.device.descriptor.endpointID.caseInsensitiveCompare(peer.endpointIDHex) == .orderedSame
        }?.device.descriptor.metadata.platform == .mac
        guard Self.allowsInboundPeer(
            isMac: isMac,
            pairingEnabled: pairingEnabled(),
            incomingAccessEnabled: MobileRemoteControlPolicy.allowsIncomingAccess()
        ) else {
            await irx.close(code: .revoked, origin: .local)
            return
        }
        let stillAuthorized: @Sendable (String) -> Bool = { endpoint in
            guard isMac ? MobileRemoteControlPolicy.allowsIncomingAccess()
                : MobileHostService.isListeningEnabled else { return false }
            if !isMac, let list = legacyCurrent?.current, let entry = list.entries[endpoint] {
                return list.isFresh(now: .now) && !entry.revoked
                    && entry.capabilities?.contains(LegacyCompatibilityService.v2Capability) != true
                    && (entry.deviceID == nil || entry.deviceID == peer.deviceID)
                    && (entry.bindingID == nil || entry.bindingID == peer.bindingID)
                    && (entry.tag == nil || entry.tag == peer.tag)
                    && (entry.identityGeneration == nil || entry.identityGeneration == peer.identityGeneration)
            }
            return admission.recheck(peer)(endpoint)
        }
        let registered = await registry.admit(
            deviceID: peer.bindingID,
            sessionID: sessionID,
            connection: irx,
            stillAuthorized: stillAuthorized
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
                    platform: isMac ? .mac : .ios,
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
                journal: journal,
                onInteractiveSurface: { surfaceID in
                    // Fire-and-forget: input delivery never waits on the
                    // output side. Keystrokes arrive at human rate.
                    Task { await eventWriter.noteInteractiveSurface(surfaceID.uuidString) }
                })
        }
        let controlTransport = IrxControlByteTransport(
            connection: irx, control: control, closeCode: .hostShutdown)
        let peerRequestHandler: (@Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult?)?
        if isMac {
            let layouts = deviceWorkspaceLayouts
            peerRequestHandler = { request in
                await layouts.handle(request)
            }
        } else {
            peerRequestHandler = nil
        }
        let exit = await MobileHostService.acceptTransport(
            controlTransport,
            authorization: .irohAdmission(admittedPeer),
            hostDeviceID: legacyCurrent?.current?.entries[peer.endpointIDHex] != nil
                ? MobileHostIdentity.deviceID() : nil,
            artifactTransfers: artifactRegistry,
            independentEventWriter: eventWriter,
            // Admission has already authenticated this bounded pooled peer.
            // It may wait for its first RPC while the client finishes setup;
            // native Iroh owns its connection lifetime.
            firstFrameTimeoutNanoseconds: 0,
            irohAdmissionIsAuthorized: { stillAuthorized(peer.endpointIDHex) },
            remoteControlDisabledByPolicy: { !stillAuthorized(peer.endpointIDHex) },
            peerRequestHandler: peerRequestHandler,
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
        journal: IrxJournal,
        onInteractiveSurface: @escaping MobileHostIrxTerminalLaneServer.InteractiveSurfaceObserver
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
                        journal: journal,
                        onInteractiveSurface: onInteractiveSurface
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
                        journal: journal,
                        onInteractiveSurface: onInteractiveSurface
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

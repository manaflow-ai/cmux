public import CmuxIrxTransport
public import Foundation

/// The cmux-next Mac's phone listener: one irx (Iroh, ALPN `cmux/irx/1`)
/// endpoint, registered as a v2 Mac device for the signed-in account and
/// team. Admission is the v2 same-account gate (`V2InboundAdmissionAuthority`),
/// unchanged from the old app; only the orchestration is new.
///
/// Admitted phones get the compat adapter on their control stream and may
/// open daemon lanes. Mac-to-Mac peers are refused: cmux-next has no
/// device-layout service yet.
public actor MobileIrxHost {
    public enum Phase: Sendable, Equatable {
        case idle
        case provisioning
        case waitingForRelay
        case listening(relayURL: String?)
        case failed(String)
        case stopped
    }

    public internal(set) var phase: Phase = .idle
    /// The v2 installation id phones see as `mac_device_id`, once provisioned.
    public internal(set) var macDeviceID: String?

    let configuration: MobileHostConfiguration
    let auth: any MobileHostAuth
    let makeBackend: @Sendable () async throws -> any MobileCompatBackend
    let clock: any Clock<Duration>
    let journal: IrxJournal

    var backend: (any MobileCompatBackend)?
    var identity: IrxIdentity?
    var admission: V2InboundAdmissionAuthority?
    var controlService: V2ControlService?
    var supervisor: IrxEndpointSupervisor?
    var registry: IrxServerSessionRegistry?
    var cachedState: V2CachedState?
    var controlTask: Task<Void, Never>?
    var endpointTask: Task<Void, Never>?
    var endpointRefreshPending = false
    var acceptTask: Task<Void, Never>?
    var expiryTask: Task<Void, Never>?

    public init(configuration: MobileHostConfiguration, auth: any MobileHostAuth,
                makeBackend: @escaping @Sendable () async throws -> any MobileCompatBackend,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.configuration = configuration
        self.auth = auth
        self.makeBackend = makeBackend
        self.clock = clock
        journal = IrxJournal(subsystem: "com.cmuxterm.app.next", category: "irx-host",
                             journalFileURL: URL(fileURLWithPath: "/tmp/cmux-next-irx-journal-\(configuration.tag).jsonl"))
    }

    /// Provisions the v2 device and starts listening. Idempotent.
    public func start() async {
        guard phase == .idle || phase == .stopped || { if case .failed = phase { true } else { false } }() else { return }
        phase = .provisioning
        do {
            try await provision()
        } catch {
            journal.record("next-host", "provision-failed", ["error": String(describing: error)])
            await teardown()
            phase = .failed(String(describing: error))
        }
    }

    /// Closes every phone session and stops the endpoint and control service.
    public func stop() async {
        await teardown()
        phase = .stopped
    }

    /// Compat host identity reported in `mobile.host.status`.
    func hostInfo(macDeviceID: String) -> MobileCompatHostInfo {
        MobileCompatHostInfo(macDeviceID: macDeviceID, instanceTag: configuration.tag,
                             bundleIdentifier: configuration.namespace, displayName: configuration.displayName,
                             appVersion: configuration.appVersion, appBuild: configuration.appBuild,
                             daemonLaneAvailable: true)
    }

    private func provision() async throws {
        let keys = MobileHostKeys(configuration: configuration)
        let deviceID = try keys.deviceID()
        let tuple = V2Identity(appNamespace: configuration.namespace, buildTag: configuration.tag,
                               deviceID: deviceID, environment: configuration.environment,
                               projectID: auth.projectID, teamID: auth.teamID, userID: auth.userID)
        let key = try await keys.key(identity: tuple)
        let store = V2FileStateStore(rootDirectory: configuration.stateDirectory, fileManager: FileManager(),
                                     identityKey: key)
        let restored = try await store.load(identity: tuple)
        let device = V2DeviceDescriptor(
            endpointID: key.endpointID, identity: tuple,
            identityGeneration: restored?.device?.descriptor.identityGeneration ?? 1,
            metadata: V2DeviceMetadata(appVersion: configuration.appVersion, capabilities: ["irx-v2"],
                                       displayName: configuration.displayName, pairingEnabled: true,
                                       platform: .mac,
                                       relayURLs: restored?.device?.descriptor.metadata.relayURLs ?? []))
        let identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: deviceID, appInstanceID: key.endpointID)
        let admission = try V2InboundAdmissionAuthority(host: device)
        if let restored { _ = admission.restore(restored) }
        let auth = auth
        let http = V2URLSessionHTTPTransport(session: .shared)
        let dependencies = V2ControlDependencies(
            connect: { V2URLSessionSocket(session: .shared, request: $0) },
            http: { try await http.send($0) },
            stackAccessToken: { force in
                guard await auth.isCurrent() else { throw V2ControlFailure.scopeMismatch }
                return try await auth.accessToken(forceRefresh: force)
            },
            sign: { data in
                guard await auth.isCurrent() else { throw V2ControlFailure.scopeMismatch }
                return try key.sign(data)
            },
            journal: journal)
        let service = V2ControlService(configuration: try .init(baseURL: configuration.baseURL, device: device),
                                       dependencies: dependencies, store: store)
        backend = try await makeBackend()
        self.identity = identity
        self.admission = admission
        macDeviceID = deviceID
        registry = IrxServerSessionRegistry(journal: journal)
        supervisor = IrxEndpointSupervisor(
            configuration: .init(identity: identity, pathMode: .automatic,
                                 preferredBindAddress: "0.0.0.0:\(configuration.preferredPort)",
                                 initialRemoteBiStreams: 1, initialRemoteUniStreams: 0, additionalALPNs: []),
            journal: journal)
        cachedState = restored ?? V2CachedState(identity: tuple)
        controlService = service
        phase = .waitingForRelay
        // A returning Mac listens from its cache while the control plane connects.
        requestEndpointReady()
        controlTask = Task { [weak self] in
            for await snapshot in await service.events() {
                guard let self, !Task.isCancelled else { return }
                await self.apply(snapshot)
                await service.acknowledgeApplied(sequence: snapshot.sequence)
            }
        }
        await service.start()
        journal.record("next-host", "control-started", ["cached": String(restored != nil)])
    }

    private func apply(_ snapshot: V2ControlSnapshot) async {
        guard let admission else { return }
        // The service publishes an empty observation before loading disk.
        guard snapshot.cache.device != nil || cachedState?.device == nil || snapshot.cache.authorityRevoked else { return }
        let previousCredentials = cachedState?.relayCredentials
        cachedState = snapshot.cache
        _ = admission.apply(snapshot)
        if snapshot.cache.authorityRevoked {
            journal.record("next-host", "authority-revoked", [:])
            await teardown()
            phase = .failed("this Mac was removed from the account's devices")
            return
        }
        await enforcePermissions()
        scheduleExpiry()
        if previousCredentials != snapshot.cache.relayCredentials, let supervisor {
            await supervisor.rotateCredentials(Self.credentials(snapshot.cache))
        }
        requestEndpointReady()
    }

    func teardown() async {
        controlTask?.cancel(); controlTask = nil
        endpointTask?.cancel(); endpointTask = nil
        acceptTask?.cancel(); acceptTask = nil
        expiryTask?.cancel(); expiryTask = nil
        admission?.invalidate()
        await registry?.closeAll(code: .hostShutdown)
        await supervisor?.deactivate()
        await controlService?.stop()
        controlService = nil
        supervisor = nil
        registry = nil
        admission = nil
        backend = nil
    }

    static func credentials(_ cache: V2CachedState) -> [IrxRelayCredential] {
        cache.relayCredentials.map {
            IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
                               expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
                               refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter)))
        }
    }
}

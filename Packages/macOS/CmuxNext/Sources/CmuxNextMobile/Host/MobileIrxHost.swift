public import CmuxIrxTransport
import CmuxNextDaemon
import CmuxNextWakeups
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
    /// Called once per phone connection that becomes usable (`mobile.rpc.ready`).
    let onUsable: (@Sendable (MobileUsableSession) -> Void)?

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
    var expiryTimer: DemandTimer?
    /// Spacing of endpoint activation attempts; reset once the endpoint is ready.
    var endpointPacer = RetryPacer(MobileIrxHost.endpointRetry)
    /// Spacing of endpoint cycles whose accept loop ended without accepting
    /// anything; reset when a connection is accepted.
    var acceptPacer = RetryPacer(MobileIrxHost.acceptRetry)
    /// A relay-state change cuts the activation backoff short.
    let endpointWake = RetryWake(owner: "MobileIrxHost.endpoint")
    var acceptRestart: DemandTimer?
    /// Bumped by every `start()` and `stop()`. A provisioning run checks it
    /// after each await and abandons itself once stale, so a stop that lands
    /// mid-provisioning cannot be undone by the start resuming afterwards.
    var lifetime: UInt64 = 0

    /// Thrown inside `provision` when a newer `start()`/`stop()` took over.
    struct Superseded: Error {}

    public init(configuration: MobileHostConfiguration, auth: any MobileHostAuth,
                makeBackend: @escaping @Sendable () async throws -> any MobileCompatBackend,
                clock: any Clock<Duration> = ContinuousClock(),
                onUsable: (@Sendable (MobileUsableSession) -> Void)? = nil) {
        self.onUsable = onUsable
        self.configuration = configuration
        self.auth = auth
        self.makeBackend = makeBackend
        self.clock = clock
        journal = IrxJournal(subsystem: "com.cmuxterm.app.next", category: "irx-host",
                             journalFileURL: URL(fileURLWithPath: "/tmp/cmux-next-irx-journal-\(configuration.tag).jsonl"))
    }

    /// Provisions the v2 device and starts listening. Idempotent.
    public func start() async {
        switch phase {
        case .idle, .stopped, .failed: break
        case .provisioning, .waitingForRelay, .listening: return
        }
        lifetime += 1
        let run = lifetime
        phase = .provisioning
        // A relay failure leaves the endpoint and control service running;
        // release them before provisioning new ones (no-op otherwise).
        await teardown()
        do {
            try ensureCurrent(run)
            try await provision(run: run)
        } catch is Superseded {
            journal.record("next-host", "provision-superseded", [:])
        } catch {
            guard run == lifetime else { return }
            journal.record("next-host", "provision-failed", ["error": String(describing: error)])
            await teardown()
            if run == lifetime { phase = .failed(String(describing: error)) }
        }
    }

    /// Closes every phone session and stops the endpoint and control service.
    public func stop() async {
        lifetime += 1
        phase = .stopped
        await teardown()
    }

    private func ensureCurrent(_ run: UInt64) throws {
        guard run == lifetime else { throw Superseded() }
    }

    /// Compat host identity reported in `mobile.host.status`.
    func hostInfo(macDeviceID: String) -> MobileCompatHostInfo {
        MobileCompatHostInfo(macDeviceID: macDeviceID, instanceTag: configuration.tag,
                             bundleIdentifier: configuration.namespace, displayName: configuration.displayName,
                             appVersion: configuration.appVersion, appBuild: configuration.appBuild,
                             daemonLaneAvailable: true)
    }

    private func provision(run: UInt64) async throws {
        let keys = MobileHostKeys(configuration: configuration)
        let deviceID = try keys.deviceID()
        let tuple = V2Identity(appNamespace: configuration.namespace, buildTag: configuration.tag,
                               deviceID: deviceID, environment: configuration.environment,
                               projectID: auth.projectID, teamID: auth.teamID, userID: auth.userID)
        let key = try await keys.key(identity: tuple)
        try ensureCurrent(run)
        let store = V2FileStateStore(rootDirectory: configuration.stateDirectory, fileManager: FileManager(),
                                     identityKey: key)
        let restored = try await store.load(identity: tuple)
        try ensureCurrent(run)
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
        let made = try await makeBackend()
        try ensureCurrent(run)
        // From here to `service.start()` nothing suspends, so the resources
        // below belong to this run; a later `stop()` tears them down.
        backend = made
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
        guard run == lifetime else {
            // Stopped while the service started: teardown already ran and
            // released everything above; stop the service it could not reach.
            await service.stop()
            throw Superseded()
        }
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
        expiryTimer?.cancel(); expiryTimer = nil
        acceptRestart?.cancel(); acceptRestart = nil
        endpointPacer.reset()
        acceptPacer.reset()
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

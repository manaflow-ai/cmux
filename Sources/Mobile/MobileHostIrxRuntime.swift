import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation
import OSLog

/// macOS composition root for the irx transport (the from-scratch iroh
/// rebuild in `CmuxIrxTransport`). DEBUG-only and default-off: when
/// `cmux.irx.enabled` is set (or `CMUX_IRX_ENABLED=1`), this runtime owns the
/// app's iroh identity slot and the legacy `MobileHostIrohRuntime` stays
/// dormant, so the two stacks can never fight over the broker binding.
@MainActor
final class MobileHostIrxRuntime {
    static let shared = MobileHostIrxRuntime()

    nonisolated static let enabledDefaultsKey = "cmux.irx.enabled"
    nonisolated static let forceRelayDefaultsKey = "cmux.irx.force-relay"

    /// irx is the PRIMARY transport: on by default in every configuration.
    /// An explicit `false` in defaults (the remote revert switch writes it)
    /// falls back to the legacy runtime; the env var re-arms and persists.
    nonisolated static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_ENABLED"] == "1" {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        return true
    }

    nonisolated static var forceRelayOnly: Bool {
        if ProcessInfo.processInfo.environment["CMUX_IRX_FORCE_RELAY"] == "1" {
            UserDefaults.standard.set(true, forKey: forceRelayDefaultsKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: forceRelayDefaultsKey)
    }

    /// One journal for every irx component on the Mac. The soak analyzer
    /// tails the JSONL file; `log show` sees the mirrored notice lines.
    nonisolated static let journal: IrxJournal = {
        let tag = MobileHostIdentity.instanceTag()
        return IrxJournal(
            subsystem: "dev.cmux",
            category: "irx-host",
            journalFileURL: URL(
                fileURLWithPath: "/tmp/cmux-irx-journal-mac-\(tag).jsonl")
        )
    }()

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var activationTask: Task<Void, Never>?
    /// Changes on every (de)activation; per-connection supervisors compare it.
    private var generationToken = UUID()

    /// Coarse lifecycle mirror for the Settings Networking section (see
    /// `MobileHostIrxRuntime+SettingsControl`). `failed` means the last
    /// activation attempt errored and the retry ladder owns recovery; it is
    /// only cleared by a successful activation or an account change.
    enum SettingsPhase: Equatable {
        case idle
        case activating
        case active
        case failed
    }

    private(set) var settingsPhase: SettingsPhase = .idle
    /// True once an authenticated broker discovery succeeded during the
    /// current activation, so Settings can report the relay fleet as
    /// server-verified rather than served from the disk cache.
    private(set) var hadLiveDiscoveryThisRun = false
    /// Live settings-snapshot subscribers (`irohSettingsUpdates()`).
    var irxSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    /// Periodic re-yield loop; runs only while subscribers exist.
    var irxSettingsRefreshTask: Task<Void, Never>?

    private(set) var brokerService: IrxBrokerService?
    private(set) var endpointSupervisor: IrxEndpointSupervisor?
    private var autopilot: IrxRelayCredentialAutopilot?
    private var registry: IrxServerSessionRegistry?
    private var acceptLoop: Task<Void, Never>?
    private var localBinding: IrxBindingSnapshot?
    /// The always-on fact channel to the per-account control-plane DO: the
    /// host publishes hint announcements on it (instant propagation to
    /// phones) and ingests pushed relay passes. Never on any serving path.
    private var controlPlane: IrxControlPlaneClient?

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        Self.journal.record(
            "host-runtime", "configured",
            ["force_relay": String(Self.forceRelayOnly)]
        )
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                let accountID = auth.currentUser?.id
                if accountID != self?.activeAccountID {
                    await self?.transition(to: accountID)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Sets the settings-facing phase and pushes a fresh snapshot to any
    /// Settings subscribers. Safe to call redundantly; only changes publish.
    func setSettingsPhase(_ phase: SettingsPhase) {
        guard phase != settingsPhase else { return }
        settingsPhase = phase
        publishIrxSettingsUpdate()
    }

    /// Marks the current run as having completed a live (network) broker
    /// discovery, so the Settings policy source reads "server". Called from
    /// activation and from the settings refresh action.
    func noteLiveDiscoverySucceeded() {
        hadLiveDiscoveryThisRun = true
    }

    private func transition(to accountID: String?) async {
        guard accountID != activeAccountID else { return }
        await deactivate()
        activeAccountID = accountID
        guard let accountID else { return }
        Self.journal.record("host-runtime", "activating", ["account": accountID])
        setSettingsPhase(.activating)
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    private func activate(accountID: String) async {
        guard let auth else { return }
        generationToken = UUID()
        let token = generationToken
        let tag = MobileHostIrohRuntime.currentTag()
        guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL,
            let namespace = CmxIrohMacBundleNamespace(
                bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            Self.journal.record("host-runtime", "activation-failed", ["reason": "environment"])
            setSettingsPhase(.failed)
            return
        }
        let stateDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("cmux-irx", isDirectory: true)
        do {
            // IDENTITY ADOPTION: reuse the legacy stack's identity, device
            // ID, and app-instance scope, so the EndpointID, binding slot,
            // and every existing pair grant carry over (refresh-in-place;
            // stored routes on phones keep working with zero re-pairing).
            let legacy = MobileHostIrohRuntime.shared
            let appInstanceID = try await legacy.appInstances.appInstanceID(
                accountID: accountID, tag: tag)
            let material = try await legacy.identities.identity(
                accountID: accountID, appInstanceID: appInstanceID)
            let deviceID = cmxCanonicalDeviceID(MobileHostIdentity.deviceID())
            let identity = IrxIdentity(
                privateKeyData: material.secretKey.bytes,
                deviceID: deviceID,
                appInstanceID: appInstanceID
            )
            let broker = try IrxBrokerService(
                configuration: .init(
                    baseURL: brokerBaseURL,
                    clientNamespace: namespace.rawValue,
                    tag: tag,
                    platform: .mac,
                    displayName: Host.current().localizedName,
                    cacheDirectory: stateDir,
                    identityGeneration: material.generation
                ),
                identity: identity,
                accessTokenPair: { [weak auth] in
                    guard let auth else { return nil }
                    let session = try await auth.authenticatedSessionSnapshot()
                    return (session.accessToken, session.refreshToken)
                },
                journal: Self.journal
            )
            brokerService = broker

            // Credentials first (the relay-token bootstrap phase works before
            // the binding exists), so registration can advertise the relay
            // hint peers dial first.
            let legacyListener = MobileHostIrxLegacyDialectServer.listenerEnabled
            let supervisor = IrxEndpointSupervisor(
                configuration: .init(
                    identity: identity,
                    pathMode: Self.forceRelayOnly ? .relayOnly : .automatic,
                    preferredBindAddress: nil,
                    // The phone opens control/keepalive/terminal/artifact
                    // lanes; 1 is enough to admit, raised post-admission.
                    initialRemoteBiStreams: 1,
                    initialRemoteUniStreams: 0,
                    // Dual ALPN: old phones speak the legacy dialect against
                    // the SAME endpoint/identity while irx is primary.
                    additionalALPNs: legacyListener
                        ? [MobileHostIrxLegacyDialectServer.legacyALPN] : []
                ),
                journal: Self.journal
            )
            endpointSupervisor = supervisor
            let pilot = IrxRelayCredentialAutopilot(
                broker: broker, endpoint: supervisor, journal: Self.journal)
            autopilot = pilot
            // Registration FIRST: non-legacy namespaces need the binding
            // authorization it establishes before any other broker call
            // (relay minting, discovery) is accepted.
            let binding = try await broker.register(
                pairingEnabled: true,
                relayURLHint: nil
            )
            localBinding = binding
            let credentials = try await pilot.usableCredentials()
            _ = try await broker.discover()
            noteLiveDiscoverySucceeded()

            guard generationToken == token else { return }
            _ = try await supervisor.readyEndpoint(credentials: credentials)
            // Advertise the relay the endpoint ACTUALLY homes on, then
            // refresh the binding so registry consumers see it too.
            let homeRelay = await supervisor.homeRelayURL() ?? credentials.first?.relayURL
            _ = try? await broker.register(pairingEnabled: true, relayURLHint: homeRelay)
            // Control-plane socket: hint announcements out (instant phone
            // propagation, the signed HTTPS registration stays authoritative)
            // and pushed relay passes in (same mint rules as HTTPS).
            let control: IrxControlPlaneClient?
            if let controlURL = PresenceHeartbeatClient.resolvedServiceURL() {
                let client = IrxControlPlaneClient(
                    configuration: .init(
                        socketURL: controlURL
                            .appendingPathComponent("v1/control/socket"),
                        endpointIDHex: identity.endpointIDHex,
                        // Phase A: passes stay on the HTTPS autopilot (with
                        // the stale-connection retry). The broker mint
                        // requires an endpoint-signed proof for non-legacy
                        // namespaces, which a bearer-only proxy cannot
                        // satisfy; flip when proof pass-through ships.
                        wantPasses: false,
                        cacheDirectory: stateDir
                    ),
                    accessToken: { [weak auth] in
                        try await auth?.authenticatedSessionSnapshot().accessToken
                    },
                    handlers: .init(
                        onRelayPasses: { [weak self, weak broker, weak supervisor, weak pilot] pushed in
                            guard let broker, let supervisor, let pilot,
                                let accepted = await broker
                                    .acceptPushedRelayCredentials(pushed)
                            else { return }
                            await supervisor.rotateCredentials(accepted)
                            await pilot.kick()
                            await self?.publishIrxSettingsUpdate()
                        },
                        // The host dials no peers; hint/directory facts are
                        // for clients.
                        onHintUpdate: { _, _ in },
                        onDirectory: { _ in },
                        onSnapshotComplete: { _ in }
                    ),
                    journal: Self.journal
                )
                controlPlane = client
                control = client
                await client.start()
                if let homeRelay {
                    await client.publishHint(homeRelayURL: homeRelay)
                }
            } else {
                control = nil
            }
            // Relay hints are server-capped at 1h; refresh the registration on
            // every credential rotation so the advertised hint never expires,
            // and announce it over the socket so phones hear about relay
            // moves in milliseconds instead of at the next registry read.
            await pilot.setOnRotation { [weak self, weak broker, weak supervisor] in
                guard let broker, let supervisor else { return }
                let relay = await supervisor.homeRelayURL()
                try? await broker.registerHintIfNeeded(
                    pairingEnabled: true, relayURLHint: relay)
                if let relay, let control {
                    await control.publishHint(homeRelayURL: relay)
                }
                // Credential rotation (and any home-relay move it reveals)
                // changes the Settings snapshot's policy expiry and relay
                // selection; push it to live subscribers.
                await self?.publishIrxSettingsUpdate()
            }
            await pilot.start()
            registry = IrxServerSessionRegistry(journal: Self.journal)

            publishRoute(identity: identity, relayURL: homeRelay)
            startAcceptLoop(token: token)
            Self.journal.record(
                "host-runtime", "active",
                [
                    "endpoint_id": identity.endpointIDHex,
                    "binding": binding.bindingID,
                    "tag": tag,
                    "path_mode": Self.forceRelayOnly ? "relay-only" : "automatic",
                ]
            )
            setSettingsPhase(.active)
        } catch {
            Self.journal.record(
                "host-runtime", "activation-failed",
                ["reason": String(describing: error)]
            )
            if generationToken == token {
                // Stays failed across the retry ladder (no activating/failed
                // flicker in Settings); success or an account change clears it.
                setSettingsPhase(.failed)
            }
            // One bounded retry ladder, reset by the auth observation loop on
            // account change: retry activation after 5s while still desired.
            try? await Task.sleep(for: .seconds(5))
            if generationToken == token, activeAccountID == accountID {
                await activate(accountID: accountID)
            }
        }
    }

    private func deactivate() async {
        generationToken = UUID()
        acceptLoop?.cancel()
        acceptLoop = nil
        activationTask?.cancel()
        activationTask = nil
        if let autopilot {
            await autopilot.stop()
        }
        autopilot = nil
        if let registry {
            await registry.closeAll(code: .hostShutdown)
        }
        registry = nil
        if let controlPlane {
            await controlPlane.stop()
        }
        controlPlane = nil
        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        endpointSupervisor = nil
        brokerService = nil
        localBinding = nil
        hadLiveDiscoveryThisRun = false
        setSettingsPhase(.idle)
        if Self.isEnabled {
            MobileHostPublicStatusCache.update(irohIdentity: nil)
        }
        Self.journal.record("host-runtime", "deactivated")
    }

    /// Publishes the irx endpoint as THE iroh route: attach tickets, host
    /// status, and presence all advertise it, so phones dial irx. v1 hints
    /// carry the relay URL only (relay-first; private hints require network
    /// profiles the irx runtime deliberately does not synthesize yet).
    private func publishRoute(identity: IrxIdentity, relayURL: String?) {
        guard let peerIdentity = try? CmxIrohPeerIdentity(endpointID: identity.endpointIDHex)
        else { return }
        var hints: [CmxIrohPathHint] = []
        let now = Date()
        if let relayURL,
            let hint = try? CmxIrohPathHint(
                kind: .relayURL,
                value: relayURL,
                source: .native,
                privacyScope: .publicInternet,
                observedAt: now,
                expiresAt: now.addingTimeInterval(30 * 60)
            )
        {
            hints.append(hint)
        }
        MobileHostPublicStatusCache.update(irohIdentity: peerIdentity, pathHints: hints)
        Self.journal.record(
            "host-runtime", "route-published",
            ["hints": String(hints.count), "relay": relayURL ?? "-"]
        )
    }

    private func startAcceptLoop(token: UUID) {
        guard let endpointSupervisor, let brokerService, let registry, let localBinding
        else { return }
        let journal = Self.journal
        guard let acceptor = try? acceptorPeer(binding: localBinding) else {
            journal.record("host-runtime", "activation-failed", ["reason": "acceptor-tuple"])
            return
        }
        // Admission reads the persisted trust snapshot synchronously; it
        // never awaits the broker (steady-state independence).
        let judge = IrxGrantJudge(
            acceptor: acceptor,
            trustProvider: { IrxDiskCacheTrustReader.read() }
        )
        let trustSnapshot = { IrxDiskCacheTrustReader.read() }
        let brokerClient = brokerService.hostBrokerClient
        acceptLoop = Task { [weak self] in
            journal.record("host-runtime", "accept-loop-started")
            while !Task.isCancelled {
                guard let inbound = await endpointSupervisor.acceptNextInbound() else {
                    // Endpoint closed or unbound: rebind with the freshest
                    // cached credentials and continue accepting.
                    do {
                        let credentials = await brokerService.cachedRelayCredentials()
                        _ = try await endpointSupervisor.readyEndpoint(credentials: credentials)
                    } catch {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    continue
                }
                switch inbound {
                case .irx(let irx):
                    Task { [weak self] in
                        await self?.superviseConnection(
                            irx, judge: judge, registry: registry, token: token)
                    }
                case .foreign(let alpn, let connection):
                    guard alpn == MobileHostIrxLegacyDialectServer.legacyALPN,
                        MobileHostIrxLegacyDialectServer.listenerEnabled,
                        let trust = trustSnapshot(),
                        let adopted = try? CmxIrohLibEndpointFactory
                            .adoptAcceptedConnection(connection)
                    else {
                        try? connection.close(
                            errorCode: 1, reason: Data("unsupported_alpn".utf8))
                        continue
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        await MobileHostIrxLegacyDialectServer.serve(
                            adopted: adopted,
                            acceptor: acceptor,
                            trust: trust,
                            brokerClient: brokerClient,
                            isCurrent: { [weak self] in
                                let runtime = self
                                return await MainActor.run { runtime?.generationToken == token }
                            },
                            journal: journal
                        )
                    }
                }
            }
        }
    }

    private nonisolated func acceptorPeer(binding: IrxBindingSnapshot) throws -> CmxIrohGrantPeer {
        CmxIrohGrantPeer(
            bindingID: binding.bindingID,
            deviceID: binding.deviceID,
            tag: binding.tag,
            platform: .mac,
            endpointID: try CmxIrohPeerIdentity(endpointID: binding.endpointIDHex),
            identityGeneration: binding.identityGeneration
        )
    }

    private func superviseConnection(
        _ irx: IrxConnection,
        judge: IrxGrantJudge,
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
        await registry.admit(deviceID: peer.deviceID, sessionID: sessionID, connection: irx)

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
            isCurrent: { [weak self] in
                let runtime = self
                return await MainActor.run { runtime?.generationToken == token }
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
        await registry.remove(deviceID: peer.deviceID, sessionID: sessionID)
    }

    /// Post-admission lane dispatch: keepalive echo, terminal streams over
    /// the byte tee, artifact reads. Quotas mirror the legacy router.
    private nonisolated static func runLaneLoop(
        _ irx: IrxConnection,
        admittedPeer: CmxIrohAdmittedPeer,
        artifactRegistry: MobileHostIrohArtifactTransferRegistry,
        journal: IrxJournal
    ) async {
        var terminalLaneCount = 0
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
                guard terminalLaneCount < 4 else {
                    await lane.writer.reset(errorCode: 3)
                    await lane.reader.stop(errorCode: 3)
                    continue
                }
                terminalLaneCount += 1
                let resource = lane.descriptor.resource ?? ""
                let cursor = lane.descriptor.cursor
                Task {
                    await MobileHostIrxTerminalLaneServer.serve(
                        resourceID: resource,
                        cursor: cursor,
                        stream: lane.bidirectional(),
                        journal: journal
                    )
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
            case .control, .events, .simulatorStream:
                // control arrives only pre-admission; events is server-opened;
                // simulator streaming is not served by irx v1.
                await lane.writer.reset(errorCode: 2)
                await lane.reader.stop(errorCode: 2)
            }
        }
    }
}

/// Synchronous trust-snapshot reader for the admission path (no actor hop,
/// no network): reads the JSON the broker service persists.
enum IrxDiskCacheTrustReader {
    nonisolated static func read() -> IrxTrustSnapshot? {
        let stateDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("cmux-irx", isDirectory: true)
        return IrxDiskCache<IrxTrustSnapshot>(
            fileURL: stateDir.appendingPathComponent("trust.json")
        ).load()
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

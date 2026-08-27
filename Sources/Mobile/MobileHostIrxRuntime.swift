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

    /// The activation gate, readable before any runtime exists. Release
    /// builds compile the code but can never enable it.
    nonisolated static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_IRX_ENABLED"] == "1" {
            // Sticky: launch-env opt-in persists so later env-less launches
            // (queue drains, manual taps, sim-leg relaunches) stay in irx mode.
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        #else
        return false
        #endif
    }

    nonisolated static var forceRelayOnly: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_IRX_FORCE_RELAY"] == "1" {
            UserDefaults.standard.set(true, forKey: forceRelayDefaultsKey)
            return true
        }
        return UserDefaults.standard.bool(forKey: forceRelayDefaultsKey)
        #else
        return false
        #endif
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

    private var brokerService: IrxBrokerService?
    private var endpointSupervisor: IrxEndpointSupervisor?
    private var autopilot: IrxRelayCredentialAutopilot?
    private var registry: IrxServerSessionRegistry?
    private var acceptLoop: Task<Void, Never>?
    private var localBinding: IrxBindingSnapshot?

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

    private func transition(to accountID: String?) async {
        guard accountID != activeAccountID else { return }
        await deactivate()
        activeAccountID = accountID
        guard let accountID else { return }
        Self.journal.record("host-runtime", "activating", ["account": accountID])
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
            return
        }
        let stateDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("cmux-irx", isDirectory: true)
        do {
            // irx mints its own durable device UUID so its broker binding
            // occupies its own slot: it can never reincarnate the legacy
            // runtime's binding out from under another build of this Mac.
            let deviceIDURL = stateDir.appendingPathComponent("device-id")
            let deviceID: String
            if let existing = try? String(contentsOf: deviceIDURL, encoding: .utf8),
                !existing.isEmpty
            {
                deviceID = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                deviceID = UUID().uuidString.lowercased()
                try? FileManager.default.createDirectory(
                    at: stateDir, withIntermediateDirectories: true)
                try? deviceID.write(to: deviceIDURL, atomically: true, encoding: .utf8)
            }
            let identity = try IrxIdentityProvisioner.loadOrCreate(
                store: IrxFileIdentityStore(
                    fileURL: stateDir.appendingPathComponent("identity.json")),
                deviceID: cmxCanonicalDeviceID(deviceID)
            )
            let broker = try IrxBrokerService(
                configuration: .init(
                    baseURL: brokerBaseURL,
                    clientNamespace: namespace.rawValue,
                    tag: tag,
                    platform: .mac,
                    displayName: Host.current().localizedName,
                    cacheDirectory: stateDir
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
            let supervisor = IrxEndpointSupervisor(
                configuration: .init(
                    identity: identity,
                    pathMode: Self.forceRelayOnly ? .relayOnly : .automatic,
                    preferredBindAddress: nil,
                    // The phone opens control/keepalive/terminal/artifact
                    // lanes; 1 is enough to admit, raised post-admission.
                    initialRemoteBiStreams: 1,
                    initialRemoteUniStreams: 0
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

            guard generationToken == token else { return }
            _ = try await supervisor.readyEndpoint(credentials: credentials)
            // Advertise the relay the endpoint ACTUALLY homes on, then
            // refresh the binding so registry consumers see it too.
            let homeRelay = await supervisor.homeRelayURL() ?? credentials.first?.relayURL
            _ = try? await broker.register(pairingEnabled: true, relayURLHint: homeRelay)
            // Relay hints are server-capped at 1h; refresh the registration on
            // every credential rotation so the advertised hint never expires.
            await pilot.setOnRotation { [weak broker, weak supervisor] in
                guard let broker, let supervisor else { return }
                let relay = await supervisor.homeRelayURL()
                try? await broker.registerHintIfNeeded(
                    pairingEnabled: true, relayURLHint: relay)
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
        } catch {
            Self.journal.record(
                "host-runtime", "activation-failed",
                ["reason": String(describing: error)]
            )
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
        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        endpointSupervisor = nil
        brokerService = nil
        localBinding = nil
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
        acceptLoop = Task { [weak self] in
            journal.record("host-runtime", "accept-loop-started")
            while !Task.isCancelled {
                guard let irx = await endpointSupervisor.acceptNextIrxConnection() else {
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
                Task { [weak self] in
                    await self?.superviseConnection(
                        irx, judge: judge, registry: registry, token: token)
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

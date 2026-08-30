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
    var activeAccountID: String?
    var activationTask: Task<Void, Never>?
    var activationState: IrxHostActivationState = .inactive
    var lastBrokerFailure: IrxBrokerFailure?
    var hadLiveDiscovery = false
    var activationRetryTask: Task<Void, Never>?
    var activationRetryFailureCount = 0
    let activationRetryPolicy = IrxHostActivationPolicy()
    var activationRetryClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    /// Changes on every (de)activation; per-connection supervisors compare it.
    var generationToken = UUID()

    var stateDirectory: URL?
    var brokerService: IrxBrokerService?
    var endpointSupervisor: IrxEndpointSupervisor?
    var autopilot: IrxRelayCredentialAutopilot?
    var registry: IrxServerSessionRegistry?
    var acceptLoop: Task<Void, Never>?
    var localBinding: IrxBindingSnapshot?

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        Self.journal.record(
            "host-runtime", "configured",
            ["force_relay": String(Self.forceRelayOnly)]
        )
        authObservationTask?.cancel()
        authObservationTask = Task { @MainActor [weak self] in
            await auth.awaitBootstrapped()
            for await identity in auth.authenticatedSessionIdentities() {
                guard !Task.isCancelled else { return }
                await self?.transition(to: identity?.accountID)
            }
        }
    }

    private func transition(to accountID: String?) async {
        guard accountID != activeAccountID else { return }
        let preserveReauthentication = accountID == nil
            && activationState == .reauthenticationRequired
        await deactivate(preserveReauthentication: preserveReauthentication)
        activeAccountID = accountID
        guard let accountID else { return }
        activationRetryFailureCount = 0
        lastBrokerFailure = nil
        setActivationState(.activating)
        Self.journal.record("host-runtime", "activating", ["account": accountID])
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    func activate(accountID: String) async {
        guard let auth else { return }
        setActivationState(.activating)
        generationToken = UUID()
        let token = generationToken
        let tag = MobileHostIrohRuntime.currentTag()
        guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL,
            let namespace = CmxIrohMacBundleNamespace(
                bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            let failure = IrxBrokerFailure(
                operation: .register,
                error: CmxIrohTrustBrokerClientError.invalidBaseURL
            )
            Self.journal.record(
                "host-runtime", "activation-failed", failure.journalAttributes)
            setActivationState(.failed, failure: failure)
            return
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        // Per-bundle, per-backend state: another build (or another
        // environment's) caches must never be readable here, or staging
        // trust keys reject production grants at admission.
        let stateDir = IrxStateLocation.directory(
            base: appSupport,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            brokerHost: brokerBaseURL.host
        )
        IrxStateLocation.removeLegacySharedDirectory(base: appSupport)
        stateDirectory = stateDir
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
                tokenSource: .accountPinned(
                    to: accountID,
                    snapshot: { [weak auth] in
                        guard let auth else { return nil }
                        do {
                            let session = try await auth.authenticatedSessionSnapshot()
                            return CmxIrohAccountCredentialSnapshot(
                                accountID: session.accountID,
                                credentials: CmxIrohBrokerCredentials(
                                    accessToken: session.accessToken,
                                    refreshToken: session.refreshToken
                                )
                            )
                        } catch AuthError.unauthorized {
                            // A missing session is definitive; the auth
                            // coordinator owns the sign-in transition.
                            return nil
                        }
                    },
                    forceRefresh: { [weak auth] in
                        guard let auth else {
                            throw CmxIrohBrokerTokenRecoveryError.transient
                        }
                        try await auth.forceRefreshForIrohBroker()
                    }
                ),
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
            hadLiveDiscovery = true

            guard generationToken == token else { return }
            _ = try await supervisor.readyEndpoint(credentials: credentials)
            // Advertise the relay the endpoint ACTUALLY homes on, then
            // refresh the binding so registry consumers see it too.
            let homeRelay = await supervisor.homeRelayURL() ?? credentials.first?.relayURL
            _ = try await broker.registerHintIfNeeded(
                pairingEnabled: true,
                relayURLHint: homeRelay
            )
            // Relay hints are server-capped at 1h; refresh the registration on
            // every credential rotation so the advertised hint never expires.
            await pilot.setOnRotation { [weak self, weak broker, weak supervisor] in
                guard let broker, let supervisor else { return }
                let relay = await supervisor.homeRelayURL()
                try await broker.registerHintIfNeeded(
                    pairingEnabled: true, relayURLHint: relay)
                await self?.handleAutopilotSuccess(accountID: accountID, token: token)
            }
            await pilot.setOnFailure { [weak self] failure in
                guard let self else { return }
                await self.handleAutopilotFailure(
                    failure,
                    accountID: accountID,
                    token: token
                )
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
            activationRetryFailureCount = 0
            setActivationState(.active)
        } catch is CancellationError {
            return
        } catch {
            guard generationToken == token, activeAccountID == accountID else { return }
            let failure = error as? IrxBrokerFailure
                ?? IrxBrokerFailure(operation: .register, error: error)
            await handleActivationFailure(failure, accountID: accountID, token: token)
        }
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
            journal.record(
                "host-runtime", "activation-failed",
                [
                    "operation": "endpoint",
                    "failure_kind": "invalid",
                    "error_code": "acceptor_tuple",
                ]
            )
            return
        }
        // Admission reads the persisted trust snapshot synchronously; it
        // never awaits the broker (steady-state independence).
        guard let stateDirectory else { return }
        let judge = IrxGrantJudge(
            acceptor: acceptor,
            trustProvider: { IrxDiskCacheTrustReader.read(stateDirectory: stateDirectory) }
        )
        let trustSnapshot = { IrxDiskCacheTrustReader.read(stateDirectory: stateDirectory) }
        let brokerClient = brokerService.hostBrokerClient
        let rebindClock = CmxIrohSystemRelayClock()
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
                        try? await rebindClock.sleep(
                            until: rebindClock.now().addingTimeInterval(1)
                        )
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

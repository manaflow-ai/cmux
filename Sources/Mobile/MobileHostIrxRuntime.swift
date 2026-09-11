import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxSettings
import Foundation
import OSLog

/// macOS composition root for the irx transport (the from-scratch iroh
/// rebuild in `CmuxIrxTransport`). DEBUG-only and default-off: when
/// `cmux.irx.enabled` is set (or `CMUX_IRX_ENABLED=1`), this runtime owns the
/// app's iroh identity slot and the legacy `MobileHostIrohRuntime` stays
/// dormant, so the two stacks can never fight over the broker binding.
@MainActor
final class MobileHostIrxRuntime {
    static let shared = MobileHostIrxRuntime(publishesPublicHostStatus: true)

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

    /// Longest wait between two activation attempts on the doubling ladder.
    nonisolated static let maximumActivationRetryDelay: TimeInterval = 5 * 60

    /// Delay before the next activation attempt after `error`.
    ///
    /// The ladder starts at 5 s and doubles per consecutive failure up to
    /// `maximumActivationRetryDelay`. A broker `Retry-After` is a floor that
    /// wins over the ladder, and `jitterUnitInterval` (0...1) adds up to a
    /// quarter of the resulting delay so a fleet told to wait the same window
    /// does not re-mint in lockstep.
    nonisolated static func activationRetryDelay(
        after error: any Error,
        failureCount: Int,
        jitterUnitInterval: Double
    ) -> TimeInterval {
        let exponent = min(max(failureCount, 0), 16)
        let ladder = min(5 * pow(2, Double(exponent)), maximumActivationRetryDelay)
        let serverFloor = TimeInterval(
            max(0, (error as? any CmxRetryAfterProviding)?.retryAfterSeconds ?? 0)
        )
        let base = max(ladder, serverFloor)
        let jitter = min(max(jitterUnitInterval, 0), 1) * base * 0.25
        return base + jitter
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

    private let managedDevicePolicy: ManagedDevicePolicy
    /// Only the process-wide host publishes into ``MobileHostPublicStatusCache``.
    /// Test-constructed runtimes leave that cache alone so parallel suites
    /// cannot clobber the live identity, and so comparing against ``shared``
    /// cannot lazily create it.
    private let publishesPublicHostStatus: Bool

    init(
        managedDevicePolicy: ManagedDevicePolicy = ManagedDevicePolicy(),
        publishesPublicHostStatus: Bool = false
    ) {
        self.managedDevicePolicy = managedDevicePolicy
        self.publishesPublicHostStatus = publishesPublicHostStatus
    }

    var isNetworkingAllowed: Bool {
        !managedDevicePolicy.isEnforced(.disableIrohNetworking)
            && !managedDevicePolicy.isEnforced(.disableRemoteControl)
    }

    /// Tears the host down without treating the transition as a sign-out:
    /// persisted device-list leases stay so a later policy lift can re-arm
    /// the same account. Idempotent when already idle.
    func stopHost() async {
        await enqueueManagedNetworking(.stop)
    }

    /// Applies `DisableIrohNetworking` / `DisableRemoteControl` and the
    /// current signed-in account to the live IRX host. Policy activation
    /// stops the endpoint immediately; lifting it re-arms without a relaunch.
    func applyManagedNetworkingPolicy() async {
        await enqueueManagedNetworking(.reconcile)
    }

    private enum ManagedNetworkingWork {
        case stop
        case reconcile
    }

    /// Serializes policy and account transitions. `MobileHostService.stop()`
    /// and `syncToSettings()` both fire these from unstructured tasks, so
    /// without a chain a lift could run against a half-drained teardown and
    /// no-op on a still-set `activeAccountID`, or a late stop could clear the
    /// account after a re-arm and tear the new activation down. Each unit of
    /// work re-reads the policy and the account after the queue drains, so
    /// the last transition to be requested is the one that decides the state.
    private func enqueueManagedNetworking(_ work: ManagedNetworkingWork) async {
        let previous = managedNetworkingTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            switch work {
            case .stop:
                await self.performStopHost()
            case .reconcile:
                await self.performManagedNetworkingReconcile()
            }
        }
        managedNetworkingTask = task
        await task.value
    }

    private func performStopHost() async {
        guard activeAccountID != nil
            || activationTask != nil
            || settingsPhase != .idle
            || brokerService != nil
        else {
            return
        }
        await deactivate()
        activeAccountID = nil
    }

    private func performManagedNetworkingReconcile() async {
        guard isNetworkingAllowed else {
            await performStopHost()
            return
        }
        let accountID = auth?.currentUser?.id
        if accountID != activeAccountID {
            await transition(to: accountID)
        }
    }

    private weak var auth: AuthCoordinator?
    private var authObservationTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var activationTask: Task<Void, Never>?
    /// Chain head for ``enqueueManagedNetworking(_:)``.
    private var managedNetworkingTask: Task<Void, Never>?
    /// Changes on every (de)activation; per-connection supervisors compare it.
    private var generationToken = UUID()
    /// Consecutive activation failures since the last successful activation.
    /// Drives the doubling retry ladder; reset on success and on transition.
    private var activationFailureCount = 0

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

    private var stateDirectory: URL?
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
    /// The CURRENT device-list lease the accept loop judges against:
    /// synchronous O(1) reads, atomically swapped on every directory apply,
    /// cleared (fail closed) on deactivation.
    private var deviceListBox: IrxDeviceListCurrent?
    /// Durable home of the lease (Keychain in Release, dev file store in
    /// DEBUG), loaded at activation so admission works offline.
    private var deviceListStore: IrxDeviceListStore?
    /// Authenticated Bonjour publisher for the IRX endpoint. Iroh's native
    /// candidate discovery handles public paths, while this publisher makes
    /// same-account LAN candidates available to the client-side fallback.
    private let lanPublisher = CmxIrohLANHostPublisher()

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
                // Account changes and MDM policy share this cadence so a
                // profile that never posts UserDefaults notifications still
                // lands. `syncToSettings()` also calls the same reconcile
                // immediately on an observed policy transition.
                await self?.applyManagedNetworkingPolicy()
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
        // Explicit sign-out (account -> nil): erase the persisted device-list
        // lease alongside the in-memory clear deactivate() performs, in the
        // same breath the account's other cached authorization material
        // stops being usable. An account SWITCH keeps the old account's
        // lease (it is account-scoped and TTL-bounded).
        if accountID == nil, let deviceListStore {
            await deviceListStore.clear()
        }
        await deactivate()
        activeAccountID = accountID
        activationFailureCount = 0
        guard let accountID else { return }
        Self.journal.record("host-runtime", "activating", ["account": accountID])
        setSettingsPhase(.activating)
        activationTask = Task { @MainActor [weak self] in
            await self?.activate(accountID: accountID)
        }
    }

    private func activate(accountID: String) async {
        guard isNetworkingAllowed, !Task.isCancelled, let auth else { return }
        generationToken = UUID()
        let token = generationToken
        // The control-plane client now starts EARLY in activation (before the
        // broker calls that can throw), so a retry after a mid-activation
        // failure must stop the previous attempt's client instead of leaking
        // its reconnect loop beside a fresh one.
        if let controlPlane {
            await controlPlane.stop()
            self.controlPlane = nil
        }
        let tag = MobileHostIrohRuntime.currentTag()
        guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL,
            let namespace = CmxIrohMacBundleNamespace(
                bundleIdentifier: Bundle.main.bundleIdentifier)
        else {
            Self.journal.record("host-runtime", "activation-failed", ["reason": "environment"])
            setSettingsPhase(.failed)
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
            try Task.checkCancellation()
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
                    identityGeneration: material.generation,
                    // Release: broker caches live in the Keychain, scoped
                    // per account + backend; DEBUG stays on the JSON files.
                    accountID: accountID
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
            registry = IrxServerSessionRegistry(journal: Self.journal)

            // DEVICE LIST: the admission authority. Load the persisted lease
            // BEFORE anything network-bound so admission works offline, and
            // start the control-plane client FIRST so the fresh directory
            // (and any revocation) lands as early as possible. Neither step
            // blocks the endpoint bind.
            let listStore = IrxDeviceListStore(
                secureStore: Self.deviceListSecureStore(stateDirectory: stateDir),
                accountID: accountID,
                backendHost: brokerBaseURL.host ?? "unknown-broker",
                journal: Self.journal
            )
            deviceListStore = listStore
            let listBox = IrxDeviceListCurrent()
            deviceListBox = listBox
            if let persisted = await listStore.loadPersisted() {
                listBox.replace(persisted)
            }
            try Task.checkCancellation()
            guard generationToken == token, isNetworkingAllowed else { return }

            // Control-plane socket: hint announcements out (instant phone
            // propagation, the signed HTTPS registration stays authoritative),
            // pushed relay passes in (same mint rules as HTTPS), and the
            // device-list directory in (admission authority).
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
                        cacheDirectory: stateDir,
                        clientInfo: IrxCtlClientInfo(
                            deviceID: deviceID,
                            platform: "mac",
                            appVersion: IrxCtlClientInfo.appVersionString(
                                infoDictionary: Bundle.main.infoDictionary),
                            releaseTrack: Self.hostReleaseTrack(),
                            capabilities: [
                                "cmux.irx.v2",
                                "list-auth",
                                "iroh.private_paths.v1",
                            ]
                        ),
                        clientNamespace: namespace.rawValue
                    ),
                    tokenPair: { [weak auth] in
                        guard let auth else { return nil }
                        let session = try await auth.authenticatedSessionSnapshot()
                        return (session.accessToken, session.refreshToken)
                    },
                    handlers: .init(
                        onRelayPasses: { [weak self, weak broker, weak supervisor, weak pilot] pushed in
                            guard let broker, let supervisor, let pilot,
                                let accepted = await broker
                                    .acceptPushedRelayCredentials(pushed)
                            else { return false }
                            await supervisor.rotateCredentials(accepted)
                            await pilot.kick()
                            await self?.publishIrxSettingsUpdate()
                            return true
                        },
                        // The host dials no peers; hint facts are for clients.
                        onHintUpdate: { _, _ in true },
                        onDirectory: { _ in true },
                        onSnapshotComplete: { _ in },
                        onDirectoryFact: { [weak self] fact in
                            await self?.applyDeviceListFact(fact) ?? false
                        },
                        onFreshness: { [weak self] rev, issuedAt in
                            await self?.applyDeviceListFreshness(
                                rev: rev, issuedAt: issuedAt)
                        }
                    ),
                    journal: Self.journal
                )
                controlPlane = client
                control = client
                await client.start()
            } else {
                control = nil
            }

            // Registration FIRST among the broker calls: non-legacy
            // namespaces need the binding authorization it establishes
            // before any other broker call (relay minting, discovery) is
            // accepted.
            try Task.checkCancellation()
            let binding = try await broker.register(
                pairingEnabled: true,
                relayURLHint: nil
            )
            try Task.checkCancellation()
            localBinding = binding
            let credentials = try await pilot.usableCredentials()
            try Task.checkCancellation()
            let initialDiscovery = try await broker.discover()
            noteLiveDiscoverySucceeded()

            try Task.checkCancellation()
            guard generationToken == token, isNetworkingAllowed else { return }
            _ = try await supervisor.readyEndpoint(credentials: credentials)
            try Task.checkCancellation()
            // Advertise the relay the endpoint ACTUALLY homes on, then
            // refresh the binding so registry consumers see it too.
            let homeRelay = await supervisor.homeRelayURL() ?? credentials.first?.relayURL
            let directAddresses = await supervisor.localDirectAddresses()
            let directPorts = CmxIrohDirectPorts(localDirectAddresses: directAddresses)
            try Task.checkCancellation()
            _ = try? await broker.register(
                pairingEnabled: true,
                relayURLHint: homeRelay,
                directAddresses: directAddresses,
                directPorts: directPorts
            )
            try Task.checkCancellation()
            if let control, let homeRelay {
                await control.publishHint(homeRelayURL: homeRelay)
            }
            let liveDiscovery = (try? await broker.discover(maximumAge: 0)) ?? initialDiscovery
            try Task.checkCancellation()
            if !Self.forceRelayOnly,
               MobileHostService.isListeningEnabled,
               let discoveredBinding = liveDiscovery.bindings.first(where: {
                   $0.endpointID.endpointID == identity.endpointIDHex
               }),
               let bindingMetadata = try? CmxIrohBrokerBindingMetadata(
                   bindingID: discoveredBinding.bindingID,
                   deviceID: discoveredBinding.deviceID,
                   appInstanceID: discoveredBinding.appInstanceID,
                   clientNamespace: discoveredBinding.clientNamespace,
                   tag: discoveredBinding.tag,
                   platform: discoveredBinding.platform,
                   endpointID: discoveredBinding.endpointID,
                   identityGeneration: discoveredBinding.identityGeneration,
                   pathHints: discoveredBinding.pathHints
               )
            {
                await lanPublisher.activate(
                    rendezvous: liveDiscovery.lanRendezvous,
                    binding: bindingMetadata,
                    directAddresses: { await supervisor.localDirectAddresses() }
                )
            }
            // Relay hints are server-capped at 1h; refresh the registration on
            // every credential rotation so the advertised hint never expires,
            // and announce it over the socket so phones hear about relay
            // moves in milliseconds instead of at the next registry read.
            try Task.checkCancellation()
            await pilot.setOnRotation { [weak self, weak broker, weak supervisor] in
                guard await self?.isNetworkingAllowed == true,
                      let broker, let supervisor else { return }
                let relay = await supervisor.homeRelayURL()
                let directAddresses = await supervisor.localDirectAddresses()
                let directPorts = CmxIrohDirectPorts(localDirectAddresses: directAddresses)
                try? await broker.registerHintIfNeeded(
                    pairingEnabled: true,
                    relayURLHint: relay,
                    directAddresses: directAddresses,
                    directPorts: directPorts
                )
                if let relay, let control {
                    await control.publishHint(homeRelayURL: relay)
                }
                await self?.lanPublisher.refresh()
                await self?.publishRoute(
                    identity: identity,
                    relayURL: relay,
                    directAddresses: directAddresses
                )
                // Credential rotation (and any home-relay move it reveals)
                // changes the Settings snapshot's policy expiry and relay
                // selection; push it to live subscribers.
                await self?.publishIrxSettingsUpdate()
            }
            await pilot.start()

            try Task.checkCancellation()
            publishRoute(
                identity: identity,
                relayURL: homeRelay,
                directAddresses: directAddresses
            )
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
            activationFailureCount = 0
        } catch {
            guard !Task.isCancelled, generationToken == token else { return }
            Self.journal.record(
                "host-runtime", "activation-failed",
                ["reason": String(describing: error)]
            )
            if generationToken == token {
                // Stays failed across the retry ladder (no activating/failed
                // flicker in Settings); success or an account change clears it.
                setSettingsPhase(.failed)
            }
            // One bounded retry ladder, reset on success and by the auth
            // observation loop on account change. The broker's Retry-After
            // (429 on challenge/register under mint spacing) is a floor, so a
            // rejected Mac never re-mints inside the window it was told to
            // wait out; the doubling ladder covers every other failure.
            let delay = Self.activationRetryDelay(
                after: error,
                failureCount: activationFailureCount,
                jitterUnitInterval: Double.random(in: 0 ... 1)
            )
            activationFailureCount = min(activationFailureCount + 1, 20)
            Self.journal.record(
                "host-runtime", "activation-retry-scheduled",
                [
                    "delay_s": String(Int(delay)),
                    "server_floor_s": (error as? any CmxRetryAfterProviding)?
                        .retryAfterSeconds.map(String.init) ?? "-",
                    "failure_count": String(activationFailureCount),
                ]
            )
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled, isNetworkingAllowed,
               generationToken == token, activeAccountID == accountID {
                await activate(accountID: accountID)
            }
        }
    }

    private func deactivate() async {
        generationToken = UUID()
        acceptLoop?.cancel()
        acceptLoop = nil
        let retiringActivation = activationTask
        activationTask = nil
        retiringActivation?.cancel()
        // Drain the canceled activation before releasing its resources: a
        // late endpoint bind or broker response cannot repopulate them after
        // this policy/account transition has torn them down.
        await retiringActivation?.value
        if let autopilot {
            await autopilot.stop()
        }
        autopilot = nil
        await lanPublisher.stop()
        if let registry {
            await registry.closeAll(code: .hostShutdown)
        }
        registry = nil
        if let controlPlane {
            await controlPlane.stop()
        }
        controlPlane = nil
        // Fail closed immediately: with the box cleared, the accept loop's
        // judge denies every hello. Persisted clearing happens only on
        // explicit sign-out (see `transition(to:)`), so a relaunch on the
        // same account keeps working offline.
        deviceListBox?.clear()
        deviceListBox = nil
        deviceListStore = nil
        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        endpointSupervisor = nil
        brokerService = nil
        localBinding = nil
        hadLiveDiscoveryThisRun = false
        setSettingsPhase(.idle)
        if publishesPublicHostStatus, Self.isEnabled {
            MobileHostPublicStatusCache.update(irohIdentity: nil)
        }
        Self.journal.record("host-runtime", "deactivated")
    }

    // MARK: - Device list (admission authority)

    /// Applies a pushed directory fact: build the lease snapshot, persist it,
    /// swap it into the accept path atomically, acknowledge the revision,
    /// then enforce it on LIVE sessions (a revoked or delisted device is cut
    /// now with `.revoked`, not at its next admission).
    private func applyDeviceListFact(_ fact: IrxCtlDirectoryFact) async -> Bool {
        guard let deviceListBox, let deviceListStore else { return false }
        if let current = deviceListBox.current, fact.rev <= current.rev {
            Self.journal.record(
                "host-runtime", "device-list-stale-rev",
                ["rev": String(fact.rev), "have": String(current.rev)]
            )
            return true
        }
        let snapshot = IrxDeviceListSnapshot(
            fact: fact,
            receivedAtWall: Date(),
            receivedAtMonotonic: .now
        )
        guard await deviceListStore.persist(snapshot) else { return false }
        deviceListBox.replace(snapshot)
        Self.journal.record(
            "host-runtime", "device-list-applied",
            ["rev": String(fact.rev), "entries": String(snapshot.entries.count)]
        )
        if let registry {
            await registry.closeAll(code: .revoked) { endpointIDHex in
                guard let entry = snapshot.entries[endpointIDHex] else { return true }
                return entry.revoked
            }
        }
        return true
    }

    /// An explicit freshness re-stamp (`current`, or a `snapshot_complete`
    /// carrying `issuedAt`) extends the CURRENT lease without changing its
    /// membership.
    private func applyDeviceListFreshness(rev: Int, issuedAt: Date) async {
        guard let deviceListBox, let deviceListStore else { return }
        guard
            let updated = deviceListBox.restamp(
                rev: rev,
                issuedAt: issuedAt,
                receivedAtWall: Date(),
                receivedAtMonotonic: .now
            )
        else { return }
        await deviceListStore.persist(updated)
        Self.journal.record(
            "host-runtime", "device-list-restamped", ["rev": String(rev)]
        )
    }

    /// The lease's durable backend: Keychain in Release, the development
    /// file store inside the irx state directory in DEBUG (the exact split
    /// every other secure store uses; ad-hoc DEBUG builds lack the
    /// data-protection Keychain entitlement).
    private nonisolated static func deviceListSecureStore(
        stateDirectory: URL
    ) -> any CmxIrohSecureCredentialStoring {
        #if DEBUG
        CmxIrohDevelopmentFileCredentialStore(
            directory: stateDirectory.appendingPathComponent(
                "device-list", isDirectory: true)
        )
        #else
        CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.irx.device-list.v1"
        )
        #endif
    }

    /// The Mac build's control-plane release track: DEBUG builds are "dev",
    /// nightly-flavored bundle ids are "nightly", everything else "stable".
    private nonisolated static func hostReleaseTrack() -> String {
        #if DEBUG
        return "dev"
        #else
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return bundleIdentifier.contains("nightly") ? "nightly" : "stable"
        #endif
    }

    /// Publishes the irx endpoint as THE iroh route: attach tickets, host
    /// status, and presence all advertise it, so phones dial irx. Relay and
    /// validated public direct hints are published here. Private LAN
    /// candidates stay on the authenticated Bonjour path and are never copied
    /// into the public status route.
    private func publishRoute(
        identity: IrxIdentity,
        relayURL: String?,
        directAddresses: [String] = []
    ) {
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
        if !Self.forceRelayOnly {
            for address in directAddresses {
                guard hints.count < 16,
                      let hint = try? CmxIrohPathHint(
                          kind: .directAddress,
                          value: address,
                          source: .native,
                          privacyScope: .publicInternet,
                          observedAt: now,
                          expiresAt: now.addingTimeInterval(30 * 60)
                      ) else { continue }
                if !hints.contains(hint) { hints.append(hint) }
            }
        }
        if publishesPublicHostStatus {
            MobileHostPublicStatusCache.update(irohIdentity: peerIdentity, pathHints: hints)
        }
        Self.journal.record(
            "host-runtime", "route-published",
            [
                "hints": String(hints.count),
                "direct": String(hints.count { $0.kind == .directAddress }),
                "relay": relayURL ?? "-",
            ]
        )
    }

    private func startAcceptLoop(token: UUID) {
        guard let endpointSupervisor, let brokerService, let registry, let localBinding,
            let deviceListBox
        else { return }
        let journal = Self.journal
        guard let acceptor = try? acceptorPeer(binding: localBinding) else {
            journal.record("host-runtime", "activation-failed", ["reason": "acceptor-tuple"])
            return
        }
        // LIST AUTH: irx admission judges the TLS key against the current
        // device-list lease, synchronously and O(1) (an atomic box read; no
        // actor, no disk, no network). The hello's grant is ignored.
        let judge = IrxListJudge(current: deviceListBox, journal: journal)
        // The legacy dialect (old phones) still verifies pair grants against
        // the persisted trust snapshot, read through the broker's cache so
        // the Release keychain migration cannot strand it.
        let trustSnapshot = { brokerService.cachedTrustForAdmission() }
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
        judge: IrxListJudge,
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
            deviceID: peer.deviceID,
            sessionID: sessionID,
            connection: irx,
            stillAuthorized: { endpointIDHex in
                do {
                    _ = try judge.judgment()(nil, endpointIDHex)
                    return true
                } catch {
                    return false
                }
            }
        )
        guard registered else { return }
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

/// Synchronous trust-snapshot reader for the admission path (no actor hop,
/// no network): reads the JSON the broker service persists. The caller passes
/// the per-bundle, per-broker state directory computed at activation so
/// admission never reads another build's (or another environment's) cache.
enum IrxDiskCacheTrustReader {
    /// Reads the trust snapshot from the state directory selected at activation.
    nonisolated static func read(stateDirectory: URL) -> IrxTrustSnapshot? {
        return IrxDiskCache<IrxTrustSnapshot>(
            fileURL: stateDirectory.appendingPathComponent("trust.json")
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

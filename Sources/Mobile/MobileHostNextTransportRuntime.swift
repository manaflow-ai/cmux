#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

let mobileHostNextTransportLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-next-transport"
)

/// Elapsed whole milliseconds since `start`, for diagnostics lines.
func mobileHostNextTransportElapsedMs(since start: ContinuousClock.Instant) -> Int64 {
    let elapsed = start.duration(to: ContinuousClock.now)
    return Int64(elapsed.components.seconds) * 1_000
        + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000)
}

// MARK: - Pure decision logic (no I/O; integrator wires unit tests)

/// Timing knobs for the parallel host's startup and lifecycle races.
enum NextTransportHostTiming {
    /// How long an accepted connection gets to complete the hello exchange
    /// before it is closed so it cannot wedge subsequent accepts.
    static let helloDeadlineSeconds: Int64 = 10
    /// How long a cached-credential relay handshake may hold up start();
    /// past this, startup proceeds and the relay comes up in the background.
    static let onlineDeadlineSeconds: Int64 = 10
    /// Max random jitter applied to scheduled credential refreshes so a
    /// fleet of hosts does not re-mint in lockstep.
    static let refreshJitterMaxSeconds: Int64 = 30
}

/// One persisted last-good relay credential: enough to re-attach the relay
/// on next launch without a broker round trip. Stored (JSON array) in a
/// macOS Keychain generic-password item; never in UserDefaults.
struct NextTransportCachedRelayCredential: Codable, Sendable, Equatable {
    var relayUrl: String
    var token: String
    /// Epoch seconds at which the relay stops honoring the token.
    var expiresAt: Int64
}

/// Cache-first startup policy: which persisted credentials are still worth
/// binding with, and how a fresh mint becomes cache entries.
enum NextTransportRelayCredentialCachePolicy {
    /// A cached token must outlive "now" by this margin to be included in
    /// the endpoint's initial relay map; anything tighter would expire
    /// during the bind/handshake and produce a silently dead relay route.
    static let reuseMarginSeconds: Int64 = 30

    static func usable(
        _ cached: [NextTransportCachedRelayCredential],
        now: Int64,
        marginSeconds: Int64 = reuseMarginSeconds
    ) -> [NextTransportCachedRelayCredential] {
        cached.filter { $0.expiresAt > now + marginSeconds }
    }

    /// Cache entries from a fresh mint. `Credential.expiresAt` is populated
    /// whenever an expiry is knowable (server value or the token's own JWT
    /// `exp`); a credential with no visible expiry cannot be validity-checked
    /// at the next launch, so it is not cached.
    static func entries(
        from credentials: [BrokerCredentialClient.Credential]
    ) -> [NextTransportCachedRelayCredential] {
        credentials.compactMap { credential in
            guard let expiresAt = credential.expiresAt else { return nil }
            return NextTransportCachedRelayCredential(
                relayUrl: credential.relayUrl, token: credential.token,
                expiresAt: expiresAt)
        }
    }

    static func encode(_ entries: [NextTransportCachedRelayCredential]) -> Data? {
        try? JSONEncoder().encode(entries)
    }

    static func decode(_ data: Data) -> [NextTransportCachedRelayCredential] {
        (try? JSONDecoder().decode([NextTransportCachedRelayCredential].self, from: data)) ?? []
    }
}

/// Mint-failure backoff: halve the remaining validity per retry (never a
/// hot loop — 10 s floor), and once past expiry keep trying at a bounded
/// cadence. A failed mint never tears the endpoint down.
enum NextTransportMintRetryPolicy {
    static let minimumDelaySeconds: Int64 = 10
    static let expiredCadenceSeconds: Int64 = 60

    static func retryDelay(earliestExpiry: Int64?, now: Int64) -> Int64 {
        guard let earliestExpiry, earliestExpiry > now else {
            return expiredCadenceSeconds
        }
        return max((earliestExpiry - now) / 2, minimumDelaySeconds)
    }
}

/// How start() attaches the relay leg — decided once, from what is on hand
/// at bind time. Binding itself NEVER waits on the broker.
enum NextTransportRelayPlan: Equatable {
    /// No broker client and nothing cached: the host is deliberately
    /// direct-only and skips the relay leg entirely.
    case directOnlyDeliberate
    /// Still-valid cached credentials go straight into the initial relay
    /// map; a background mint refreshes them make-before-break.
    case cachedCredential
    /// A broker client exists but nothing usable is cached: bind now with
    /// an empty relay map and attach the relay when the first background
    /// mint lands. Publication waits for that first attach.
    case awaitFirstMint

    static func make(hasBrokerClient: Bool, hasUsableCache: Bool) -> NextTransportRelayPlan {
        if hasUsableCache { return .cachedCredential }
        return hasBrokerClient ? .awaitFirstMint : .directOnlyDeliberate
    }
}

/// Graduation P4 slice 2: the cmux-lite-proven transport running as a
/// PARALLEL host inside the real Mac app — its own iroh endpoint, its own
/// ALPN (`cmux/peer/1`), its own relay registration with zero-gap
/// credential rotation — while CmuxIrohTransport continues to serve every
/// existing client untouched. Dev-gated: builds only in DEBUG, is OFF by
/// default, and starts only when the debug default opts in. No production
/// surface changes until the E1 compat verdict
/// (manaflow-ai/cmuxterm-hq#317, TRANSPORT-CONTRACT v16 D7).
///
/// Startup is cache-first and register-when-ready: the endpoint binds
/// IMMEDIATELY (with still-valid Keychain-cached relay credentials when
/// present, direct-only otherwise), the accept loop starts, and the broker
/// mint runs OFF the critical path in a background task that attaches the
/// relay make-before-break. Readiness ratchets
/// `.starting → .bound → .relayAttached → .published`; the presence route
/// and the pairing ticket exist only at `.published`
/// (`NextTransportReadiness`, cmux#9724).
@MainActor
@Observable
final class MobileHostNextTransportRuntime {
    static let shared = MobileHostNextTransportRuntime()

    /// Debug toggle (mirrors CmxIrohTransportVerificationMode's pattern).
    static let debugDefaultsKey = "dev.cmux.nextTransport.enabled"

    /// Keychain service holding the host identity and grant-signer private
    /// keys (generic-password items, one account per key).
    private static let keyStoreService = "dev.cmux.nextTransport.keys"
    private static let identityKeyAccount = "host-identity"
    private static let signerKeyAccount = "grant-signer"
    /// Keychain service holding the last-good relay credential cache.
    private static let credentialCacheService = "dev.cmux.nextTransport.relayCredentials"
    private static let credentialCacheAccount = "last-good"

    /// Legacy UserDefaults keys (pre-Keychain). Private keys migrate out of
    /// these exactly once (read old → write Keychain → delete old); the
    /// deviceID is not secret and stays in defaults.
    private static let legacyIdentityKeyDefaultsKey = "dev.cmux.nextTransport.identity.key"
    private static let legacySignerKeyDefaultsKey = "dev.cmux.nextTransport.signer.key"
    private static let identityDeviceIDDefaultsKey = "dev.cmux.nextTransport.identity.deviceID"

    /// Dev diagnostic string for the Debug menu, derived from readiness.
    private(set) var state: String = "off"
    /// Startup gate, observable so the Debug menu renders it live. Only
    /// meaningful while the host runs; reset to `.starting` on stop.
    private(set) var readiness: NextTransportReadiness = .starting
    private(set) var endpointID: String?
    private(set) var relayURL: String?
    /// Confirmed admissions only (incremented after `host.activeSession`
    /// proves the serve admitted the connection).
    private(set) var admissions = 0

    private var endpoint: Endpoint?
    private var host: TransportHost?
    private var signer: GrantSigner?
    private var startTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var serveTasks: [UInt64: Task<Void, Never>] = [:]
    private var serveTaskCounter: UInt64 = 0
    private var credentialClient: BrokerCredentialClient?
    /// Single owner for enable/disable races: every start belongs to one
    /// generation, disable bumps it, and every post-await step re-checks it,
    /// so a stale start can never publish (or clobber a newer one).
    private var generation: UInt64 = 0

    /// OFF by default, even in dev builds: the defaults key must opt in.
    /// The Debug > Next Transport toggle is the control surface.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        mobileHostNextTransportLog.notice(
            "host runtime setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))")
        UserDefaults.standard.set(enabled, forKey: Self.debugDefaultsKey)
        if enabled {
            startIfEnabled()
        } else {
            beginStop(reason: "setEnabled(false)")
        }
    }

    /// Idempotent: a host that is already starting or running is left alone.
    func startIfEnabled() {
        guard isEnabled else {
            mobileHostNextTransportLog.notice("host runtime startIfEnabled: disabled; not starting")
            return
        }
        guard startTask == nil, endpoint == nil else {
            mobileHostNextTransportLog.notice(
                """
                host runtime startIfEnabled: already \
                \(self.endpoint == nil ? "starting" : "running", privacy: .public) \
                state=\(self.state, privacy: .public); not starting again
                """)
            return
        }
        generation &+= 1
        let gen = generation
        startTask = Task { [weak self] in
            await self?.start(generation: gen)
            guard let self, self.generation == gen else { return }
            self.startTask = nil
        }
    }

    /// Tear down synchronously on the main actor (so a re-enable can start
    /// fresh immediately), closing the endpoint in the background. Bumping
    /// the generation strands any in-flight start at its next checkpoint.
    private func beginStop(reason: String) {
        mobileHostNextTransportLog.notice(
            """
            host stop begin reason=\(reason, privacy: .public) \
            state=\(self.state, privacy: .public) \
            readiness=\(self.readiness.description, privacy: .public) \
            endpoint=\(String(self.endpointID?.prefix(8) ?? "none"), privacy: .public)
            """)
        generation &+= 1
        startTask?.cancel()
        startTask = nil
        acceptTask?.cancel()
        acceptTask = nil
        credentialTask?.cancel()
        credentialTask = nil
        for task in serveTasks.values { task.cancel() }
        serveTasks.removeAll()
        MobileHostService.shared.updateNextTransportRoute(nil)
        mobileHostNextTransportLog.notice("presence route CLEARED")
        let closing = endpoint
        endpoint = nil
        host = nil
        signer = nil
        credentialClient = nil
        endpointID = nil
        relayURL = nil
        readiness = .starting
        state = "off"
        if let closing {
            // Closing also unblocks the accept loop and any hello reads the
            // cancelled tasks are still parked on (uniffi futures do not
            // observe Swift task cancellation).
            Task.detached {
                try? await closing.close()
                mobileHostNextTransportLog.notice("host endpoint closed")
            }
        }
        mobileHostNextTransportLog.notice("host stop done state=off")
    }

    // MARK: - Ticket + grant surface (gated on `.published`)

    /// Typed refusal for ticket/grant requests. `notReady` names the exact
    /// readiness rung so callers can render "not ready (state)" verbatim.
    enum RequestFailure: Error, CustomStringConvertible {
        case notReady(readiness: NextTransportReadiness, state: String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .notReady(let readiness, let state):
                return "not ready (\(readiness)); state: \(state)"
            case .encodingFailed(let what):
                return "\(what) did not encode"
            }
        }
    }

    /// The dial ticket an iOS dev build needs: host key + relay, the same
    /// shape the lab's hostd emits. Published through the debug socket
    /// (next_transport_ticket) so tooling can hand it to the phone.
    /// Available ONLY at `.published`: a ticket handed out before the relay
    /// attach and address set are current invites the half-ready dial race
    /// of cmux#9724.
    func mintTicketJSON() -> Result<String, RequestFailure> {
        guard readiness == .published, let endpoint, let signer else {
            mobileHostNextTransportLog.notice(
                """
                ticket mint refused: host not published \
                (endpoint=\(self.endpoint != nil, privacy: .public) \
                signer=\(self.signer != nil, privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                state=\(self.state, privacy: .public))
                """)
            return .failure(.notReady(readiness: readiness, state: state))
        }
        // Real LAN addresses first: bound sockets report the wildcard
        // (0.0.0.0:port), which after a loopback rewrite only a dialer ON
        // this Mac (the simulator lab) can reach. A phone on the same
        // network needs interface IPs carrying the bound port. Loopback
        // stays for the sim flows.
        let bound = endpoint.boundSockets()
        var addrs: [String] = []
        if let v4Port = bound.first(where: { $0.contains(".") })?
            .split(separator: ":").last
        {
            let interfaces =
                (try? CmxIrohSystemLANInterfaceSnapshotProvider().interfaceAddresses()) ?? []
            for interface in interfaces where interface.family == .ipv4 {
                addrs.append("\(interface.ipAddress):\(v4Port)")
            }
        }
        addrs.append(
            contentsOf: bound.map {
                $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            })
        var ticket: [String: JSONValue] = [
            "key": .data(endpoint.id().toBytes()),
            "serverKey": .data(signer.publicKeyData),
            "addrs": .array(addrs.map { .string($0) }),
        ]
        if let relayURL { ticket["relay"] = .string(relayURL) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(ticket)),
            let json = String(data: data, encoding: .utf8)
        else {
            mobileHostNextTransportLog.error("ticket mint failed: ticket JSON did not encode")
            return .failure(.encodingFailed("ticket JSON"))
        }
        mobileHostNextTransportLog.notice(
            """
            ticket minted endpoint=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
            addrs=\(addrs.joined(separator: ","), privacy: .public) \
            relay=\(self.relayURL ?? "none", privacy: .public)
            """)
        return .success(json)
    }

    /// Mint a grant for a dialing device (dev flow: the embedded signer
    /// stands in for the pairing broker, exactly as in the lab's hostd).
    /// Gated on `.published` like the ticket: a grant against a host that
    /// is not yet dialable is a paste-flow dead end.
    func mintGrant(
        deviceID: String, devicePublicKey: Data, appIdentity: String
    ) -> Result<String, RequestFailure> {
        guard readiness == .published, let signer else {
            mobileHostNextTransportLog.notice(
                """
                grant mint refused: host not published \
                device=\(String(deviceID.prefix(8)), privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                state=\(self.state, privacy: .public)
                """)
            return .failure(.notReady(readiness: readiness, state: state))
        }
        guard
            let grant = try? signer.mint(
                accountID: "acct-dev", deviceID: deviceID,
                devicePublicKey: devicePublicKey, appIdentity: appIdentity,
                grantID: "g-dev-\(UUID().uuidString.prefix(8))",
                issuedAt: Int64(Date().timeIntervalSince1970)),
            let data = try? JSONEncoder().encode(JSONValue.object(["grant": grant.payloadValue])),
            let json = String(data: data, encoding: .utf8)
        else {
            mobileHostNextTransportLog.error(
                """
                grant mint FAILED device=\(String(deviceID.prefix(8)), privacy: .public) \
                app=\(appIdentity, privacy: .public)
                """)
            return .failure(.encodingFailed("grant"))
        }
        mobileHostNextTransportLog.notice(
            """
            grant minted device=\(String(deviceID.prefix(8)), privacy: .public) \
            app=\(appIdentity, privacy: .public) \
            grantID=\(grant.grantID, privacy: .public) \
            key=\(devicePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
            """)
        return .success(json)
    }

    // MARK: - Startup (cache-first, register-when-ready)

    private func start(generation gen: UInt64) async {
        let startClock = ContinuousClock.now
        state = "starting"
        readiness = .starting
        mobileHostNextTransportLog.notice("host start begin state=starting")
        do {
            // Keys live in the Keychain (one-time migration from the legacy
            // UserDefaults copies); identity is stable per install, separate
            // from the legacy transport's identity (parallel hosts, parallel
            // keys), and the signer persists so previously minted phone
            // grants survive Mac restarts.
            let identity = await Self.loadOrCreateIdentity()
            let signer = await Self.loadOrCreateSigner()
            guard generation == gen else { return }
            self.signer = signer
            let host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
            self.host = host

            // Staging credentials via the same self-minting client the
            // phone proved in the lab. Construction reads ~/.secrets, so it
            // runs off the main actor.
            let client = await Task.detached { Self.brokerClient(identity: identity) }.value
            guard generation == gen else { return }
            credentialClient = client
            mobileHostNextTransportLog.notice(
                """
                host broker client \(client == nil ? "ABSENT (no dogfood credentials; direct-only)" : "ready", privacy: .public) \
                device=\(String(identity.deviceID.prefix(8)), privacy: .public)
                """)

            // Cache-first: bind IMMEDIATELY with still-valid cached relay
            // credentials (past the reuse margin), or without them. The
            // broker mint is never on the binding path.
            let cached = await Self.loadCachedRelayCredentials()
            guard generation == gen else { return }
            let usable = NextTransportRelayCredentialCachePolicy.usable(
                cached, now: Int64(Date().timeIntervalSince1970))
            let plan = NextTransportRelayPlan.make(
                hasBrokerClient: client != nil, hasUsableCache: !usable.isEmpty)
            mobileHostNextTransportLog.notice(
                """
                host relay plan \(String(describing: plan), privacy: .public) \
                cached=\(cached.count, privacy: .public) \
                usable=\(usable.count, privacy: .public)
                """)

            let relays = usable.map {
                IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
            }
            let endpoint: Endpoint
            switch plan {
            case .directOnlyDeliberate:
                endpoint = try await IrohSubstrate.endpoint(
                    identity: identity, minimalLoopback: false)
            case .cachedCredential, .awaitFirstMint:
                // awaitFirstMint binds NOW with an empty custom relay map;
                // the first mint inserts into it make-before-break.
                endpoint = try await IrohSubstrate.endpoint(identity: identity, relays: relays)
            }
            guard generation == gen, !Task.isCancelled else {
                try? await endpoint.close()
                return
            }
            self.endpoint = endpoint
            endpointID = endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined()
            relayURL = usable.first?.relayUrl
            mobileHostNextTransportLog.notice(
                """
                host endpoint bound id=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                sockets=\(endpoint.boundSockets().joined(separator: ","), privacy: .public) \
                elapsedMs=\(mobileHostNextTransportElapsedMs(since: startClock), privacy: .public)
                """)

            if !relays.isEmpty {
                // online() waits for the relay handshake. A cached token the
                // fleet has stopped honoring hangs it with no client-visible
                // error, so it is raced against a deadline instead of
                // trusted; the loser is abandoned, not joined (uniffi
                // futures do not observe Swift task cancellation).
                let cameOnline = await Self.raceDeadline(
                    seconds: NextTransportHostTiming.onlineDeadlineSeconds
                ) { await endpoint.online() }
                guard generation == gen else { return }
                mobileHostNextTransportLog.notice(
                    """
                    host relay online \(cameOnline ? "confirmed" : "NOT confirmed within deadline (continuing; background mint will rotate)", privacy: .public) \
                    relay=\(self.relayURL ?? "none", privacy: .public)
                    """)
            }

            startAcceptLoop(endpoint: endpoint, host: host, generation: gen)
            setReadiness(.bound, generation: gen)

            switch plan {
            case .directOnlyDeliberate:
                // Deliberately direct-only (no broker client): the relay leg
                // is skipped, not pending.
                setReadiness(.relayAttached, generation: gen)
                publishIfReady(generation: gen)
            case .cachedCredential:
                // The relay is in the map with a still-valid token: usable
                // now. Refresh runs in the background when a client exists
                // (cache without client stays cache-only until it expires).
                setReadiness(.relayAttached, generation: gen)
                publishIfReady(generation: gen)
                if let client {
                    startCredentialLoop(
                        endpoint: endpoint, client: client,
                        initialEntries: usable, generation: gen)
                }
            case .awaitFirstMint:
                // Relay attachment (and publication) wait on the first mint;
                // binding and the accept loop already did not.
                if let client {
                    startCredentialLoop(
                        endpoint: endpoint, client: client,
                        initialEntries: [], generation: gen)
                }
            }
            mobileHostNextTransportLog.notice(
                """
                next-transport host up: \(self.endpointID ?? "?", privacy: .public) \
                state=\(self.state, privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                elapsedMs=\(mobileHostNextTransportElapsedMs(since: startClock), privacy: .public)
                """)
        } catch {
            guard generation == gen else { return }
            state = "failed: \(error)"
            mobileHostNextTransportLog.error(
                """
                next-transport start failed: \(String(describing: error), privacy: .public) \
                elapsedMs=\(mobileHostNextTransportElapsedMs(since: startClock), privacy: .public)
                """)
        }
    }

    // MARK: - Readiness (ratchets upward; stale generations are inert)

    private func setReadiness(_ new: NextTransportReadiness, generation gen: UInt64) {
        guard generation == gen else {
            mobileHostNextTransportLog.notice(
                "readiness advance to \(new.description, privacy: .public) dropped: stale generation")
            return
        }
        guard readiness < new else { return }
        readiness = new
        refreshStateDescription()
        mobileHostNextTransportLog.notice(
            """
            host readiness -> \(new.description, privacy: .public) \
            state=\(self.state, privacy: .public)
            """)
    }

    /// `.published` is the ONLY place the presence route (and therefore the
    /// ticket) becomes visible; it requires `.relayAttached` first.
    private func publishIfReady(generation gen: UInt64) {
        guard generation == gen else { return }
        guard readiness >= .relayAttached else { return }
        setReadiness(.published, generation: gen)
        publishPresenceRoute()
    }

    /// Dev diagnostic (not product copy; the Debug menu renders it raw).
    private func refreshStateDescription() {
        switch readiness {
        case .starting:
            state = "starting"
        case .bound:
            state = relayURL == nil ? "bound (awaiting relay credential)" : "bound"
        case .relayAttached:
            state = relayURL == nil ? "relay-attached (direct only)" : "relay-attached"
        case .published:
            state = relayURL == nil ? "ready (direct only)" : "ready (relay)"
        }
    }

    /// Graduation slice 3: advertise the parallel host through the existing
    /// presence `routes` field. The route is identity + relay only (private
    /// addresses never enter presence), rides the same status pipeline as the
    /// iroh route so heartbeats pick it up automatically, and is facade-only:
    /// old clients drop the unknown kind at their failable-decode boundaries
    /// and no legacy selection/dial path treats it as a candidate. Reached
    /// only from generation-checked `.published` transitions (and relay-URL
    /// rotations at `.published`), so a stale start can never publish.
    private func publishPresenceRoute() {
        guard let endpointID else {
            mobileHostNextTransportLog.notice(
                "presence route publish skipped: no endpoint id")
            return
        }
        do {
            let route = try CmxAttachRoute(
                id: CmxAttachTransportKind.nextTransport.rawValue,
                kind: .nextTransport,
                endpoint: .peer(
                    id: endpointID,
                    relayHint: nil,
                    directAddrs: [],
                    relayURL: relayURL
                ),
                priority: 30
            )
            MobileHostService.shared.updateNextTransportRoute(route)
            mobileHostNextTransportLog.notice(
                """
                presence route PUBLISHED endpoint=\(String(endpointID.prefix(8)), privacy: .public) \
                relay=\(self.relayURL ?? "none", privacy: .public) priority=30
                """)
        } catch {
            mobileHostNextTransportLog.error(
                "next-transport presence route rejected: \(String(describing: error))")
        }
    }

    // MARK: - Accept loop (concurrent serves; hello deadline per connection)

    private func startAcceptLoop(endpoint: Endpoint, host: TransportHost, generation gen: UInt64) {
        acceptTask = Task { [weak self] in
            var accepted = 0
            while let connection = try? await IrohSubstrate.acceptOne(endpoint: endpoint) {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                accepted += 1
                mobileHostNextTransportLog.notice(
                    """
                    host accept-loop connection #\(accepted, privacy: .public) \
                    spawning serve task
                    """)
                // Serve in a child task so a peer that never sends its hello
                // (or a long admission) can never wedge subsequent accepts.
                self.registerServeTask(
                    connection: connection, host: host, number: accepted, generation: gen)
            }
            mobileHostNextTransportLog.notice(
                "host accept-loop exit (endpoint closed or accept failed)")
        }
    }

    private func registerServeTask(
        connection: IrohPeerConnection, host: TransportHost, number: Int, generation gen: UInt64
    ) {
        serveTaskCounter &+= 1
        let id = serveTaskCounter
        let task = Task { [weak self] in
            let served = await Self.serveWithHelloDeadline(
                connection: connection, host: host, number: number)
            guard served else {
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            guard let admitted = await host.activeSession(for: connection) else {
                mobileHostNextTransportLog.notice(
                    """
                    host serve-task connection #\(number, privacy: .public) \
                    NOT admitted (denied or closed during serve); no bridge
                    """)
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            guard let self, self.generation == gen else {
                self?.serveTasks.removeValue(forKey: id)
                return
            }
            // Count only CONFIRMED admissions (activeSession proved it).
            self.admissions &+= 1
            mobileHostNextTransportLog.notice(
                """
                host serve-task connection #\(number, privacy: .public) \
                ADMITTED session=\(admitted.id, privacy: .public) \
                device=\(String(admitted.grant.deviceID.prefix(8)), privacy: .public); \
                starting bridge
                """)
            // Router slice: an admitted connection gets the full legacy
            // application service (control RPC, lane router, server events)
            // bridged over its raw streams. The bridge runs for the session
            // lifetime inside this tracked task, so stop() can cancel it.
            await MobileHostNextTransportBridge.run(
                connection: connection,
                grant: admitted.grant,
                deviceKey: admitted.deviceKey)
            self.serveTasks.removeValue(forKey: id)
        }
        serveTasks[id] = task
    }

    /// Serve one connection under a hello deadline: `host.serve` blocks on
    /// the first control frame, and in the serial design a silent peer
    /// wedged every subsequent accept. Structured race: whichever side
    /// finishes first decides; on deadline the connection is closed INSIDE
    /// the group, which unblocks the pending hello read so the group drains
    /// (uniffi/lane reads do not observe Swift task cancellation, so a
    /// plain cancel would not release the serve child).
    private nonisolated static func serveWithHelloDeadline(
        connection: IrohPeerConnection, host: TransportHost, number: Int
    ) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await host.serve(
                    connection: connection, now: Int64(Date().timeIntervalSince1970))
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        for: .seconds(NextTransportHostTiming.helloDeadlineSeconds))
                    return false
                } catch {
                    return nil  // sleeper cancelled: serve already finished
                }
            }
            var served = true
            if let first = await group.next(), let outcome = first {
                served = outcome
            }
            if served {
                group.cancelAll()  // stop the sleeper; Task.sleep honors it
            } else {
                mobileHostNextTransportLog.notice(
                    """
                    host serve-task connection #\(number, privacy: .public) \
                    hello deadline (\(NextTransportHostTiming.helloDeadlineSeconds, privacy: .public)s) \
                    expired; closing connection
                    """)
                await connection.closeAll(reason: nil)
            }
            await group.waitForAll()
            return served
        }
    }

    // MARK: - Relay credentials (background mint; schedule-driven renewal)

    private func startCredentialLoop(
        endpoint: Endpoint, client: BrokerCredentialClient,
        initialEntries: [NextTransportCachedRelayCredential], generation gen: UInt64
    ) {
        credentialTask = Task { [weak self] in
            await self?.runCredentialLoop(
                endpoint: endpoint, client: client,
                initialEntries: initialEntries, generation: gen)
        }
    }

    /// Mint / refresh loop. Zero-gap rotation: insert ALONE with the fresh
    /// token (make-before-break; removeRelay would sever live sessions).
    /// Scheduling comes from `RelayCredentialSchedule` (the credentials' own
    /// expiries, lead, jitter) instead of the old fixed 240 s sleep; every
    /// sleep is a cancellable scheduled timer, never a poll. Failures back
    /// off by halving the remaining validity (10 s floor) and, past expiry,
    /// retry at a bounded cadence. A failed mint never tears the endpoint
    /// down: direct paths and any still-valid relay keep serving.
    private func runCredentialLoop(
        endpoint: Endpoint, client: BrokerCredentialClient,
        initialEntries: [NextTransportCachedRelayCredential], generation gen: UInt64
    ) async {
        var entries = initialEntries
        // Nothing on hand (awaitFirstMint) mints immediately; a cached
        // start refreshes on the cache's own schedule.
        var mintImmediately = entries.isEmpty
        while !Task.isCancelled, generation == gen {
            if !mintImmediately {
                let now = Int64(Date().timeIntervalSince1970)
                guard
                    let target = RelayCredentialSchedule.nextRefresh(
                        expiries: entries.map { $0.expiresAt as Int64? },
                        now: now,
                        jitterSeconds: Int64.random(
                            in: 0...NextTransportHostTiming.refreshJitterMaxSeconds))
                else { return }
                mobileHostNextTransportLog.notice(
                    """
                    host relay refresh scheduled inSeconds=\(max(target - now, 0), privacy: .public) \
                    earliestExpiry=\(entries.map(\.expiresAt).min().map(String.init) ?? "none", privacy: .public)
                    """)
                do {
                    try await Task.sleep(for: .seconds(max(target - now, 0)))
                } catch { return }
            }
            mintImmediately = false
            guard !Task.isCancelled, generation == gen else { return }
            do {
                let fresh = try await client.mint(preferredUrl: relayURL)
                guard generation == gen else { return }
                for credential in fresh {
                    try await endpoint.insertRelay(
                        config: RelayConfig(
                            url: credential.relayUrl, authToken: credential.token))
                }
                guard generation == gen else { return }
                entries = NextTransportRelayCredentialCachePolicy.entries(from: fresh)
                let previousRelayURL = relayURL
                relayURL = fresh.first?.relayUrl
                await Self.persistCachedRelayCredentials(entries)
                guard generation == gen else { return }
                mobileHostNextTransportLog.notice(
                    """
                    host relay credentials rotated zero-gap \
                    count=\(fresh.count, privacy: .public) \
                    cached=\(entries.count, privacy: .public) \
                    first=\(fresh.first?.relayUrl ?? "none", privacy: .public)
                    """)
                if readiness < .relayAttached {
                    // First successful attach on the awaitFirstMint path:
                    // the relay is now in the map and usable, so the host
                    // may advance and publish.
                    setReadiness(.relayAttached, generation: gen)
                    publishIfReady(generation: gen)
                } else if readiness == .published, relayURL != previousRelayURL {
                    // The route carries the relay URL; a rotation that moved
                    // relays must republish it.
                    publishPresenceRoute()
                }
            } catch {
                let now = Int64(Date().timeIntervalSince1970)
                let delay = NextTransportMintRetryPolicy.retryDelay(
                    earliestExpiry: entries.map(\.expiresAt).min(), now: now)
                mobileHostNextTransportLog.error(
                    """
                    credential mint failed: \(String(describing: error), privacy: .public); \
                    retry inSeconds=\(delay, privacy: .public) (endpoint stays up)
                    """)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch { return }
                mintImmediately = true
            }
        }
    }

    // MARK: - Deadline race

    /// True when `operation` finishes before the deadline. The loser is
    /// abandoned, NOT joined: uniffi async calls (`endpoint.online()`) do
    /// not observe Swift task cancellation, and joining a hung relay
    /// handshake would wedge start(). The abandoned worker completes
    /// harmlessly on its own once the endpoint closes.
    private nonisolated static func raceDeadline(
        seconds: Int64, operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        Task {
            await operation()
            continuation.yield(true)
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            continuation.yield(false)
        }
        defer { timer.cancel() }
        for await finished in stream { return finished }
        return false
    }

    // MARK: - Key storage (Keychain; one-time migration from UserDefaults)

    private nonisolated static func loadOrCreateIdentity() async -> PeerIdentity {
        let defaults = UserDefaults.standard
        if let key = await loadOrMigrateSecret(
            account: identityKeyAccount, legacyDefaultsKey: legacyIdentityKeyDefaultsKey),
            let deviceID = defaults.string(forKey: identityDeviceIDDefaultsKey)
        {
            mobileHostNextTransportLog.notice(
                "host identity LOADED device=\(String(deviceID.prefix(8)), privacy: .public)")
            return PeerIdentity(
                appIdentity: "dev.cmux.next.host", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.host",
            deviceID: defaults.string(forKey: identityDeviceIDDefaultsKey)
                ?? UUID().uuidString.lowercased())
        await storeSecret(fresh.privateKeyData, account: identityKeyAccount)
        defaults.set(fresh.deviceID, forKey: identityDeviceIDDefaultsKey)
        mobileHostNextTransportLog.notice(
            "host identity CREATED device=\(String(fresh.deviceID.prefix(8)), privacy: .public)")
        return fresh
    }

    /// The signer persists like the identity: a fresh key per launch would
    /// invalidate every previously minted phone grant on every Mac restart,
    /// forcing phones through re-credentialing.
    private nonisolated static func loadOrCreateSigner() async -> GrantSigner {
        if let key = await loadOrMigrateSecret(
            account: signerKeyAccount, legacyDefaultsKey: legacySignerKeyDefaultsKey)
        {
            let signer = GrantSigner(privateKeyData: key)
            mobileHostNextTransportLog.notice(
                """
                host signer LOADED (persisted; prior phone grants stay valid) \
                signerKey=\(signer.publicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
                """)
            return signer
        }
        let signer = GrantSigner()
        await storeSecret(signer.privateKeyData, account: signerKeyAccount)
        mobileHostNextTransportLog.notice(
            """
            host signer CREATED (fresh; any previously minted phone grants \
            are now invalid) \
            signerKey=\(signer.publicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
            """)
        return signer
    }

    /// Reads one private key from the Keychain, adopting a legacy
    /// UserDefaults copy exactly once (read old → write Keychain → delete
    /// old). A Keychain read error returns the legacy copy when present
    /// rather than minting a new key over a merely-unreadable one.
    private nonisolated static func loadOrMigrateSecret(
        account: String, legacyDefaultsKey: String
    ) async -> Data? {
        let store = CmxIrohKeychainIdentityStore(service: keyStoreService)
        var readError: (any Error)?
        do {
            if let stored = try await store.read(account: account) { return stored }
        } catch {
            readError = error
            mobileHostNextTransportLog.error(
                """
                host key Keychain read failed account=\(account, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """)
        }
        let defaults = UserDefaults.standard
        guard let legacyB64 = defaults.string(forKey: legacyDefaultsKey),
            let legacy = Data(base64Encoded: legacyB64)
        else { return nil }
        guard readError == nil else { return legacy }
        do {
            try await store.write(legacy, account: account)
            defaults.removeObject(forKey: legacyDefaultsKey)
            mobileHostNextTransportLog.notice(
                "host key MIGRATED defaults->Keychain account=\(account, privacy: .public)")
        } catch {
            // Keep the defaults copy so a later launch can retry.
            mobileHostNextTransportLog.error(
                """
                host key migration write failed account=\(account, privacy: .public) \
                error=\(String(describing: error), privacy: .public); keeping defaults copy
                """)
        }
        return legacy
    }

    private nonisolated static func storeSecret(_ data: Data, account: String) async {
        do {
            try await CmxIrohKeychainIdentityStore(service: keyStoreService)
                .write(data, account: account)
        } catch {
            mobileHostNextTransportLog.error(
                """
                host key Keychain write failed account=\(account, privacy: .public) \
                error=\(String(describing: error), privacy: .public); key is session-only
                """)
        }
    }

    // MARK: - Relay credential cache (Keychain persistence)

    private nonisolated static func loadCachedRelayCredentials()
        async -> [NextTransportCachedRelayCredential]
    {
        let store = CmxIrohKeychainCredentialStore(service: credentialCacheService)
        do {
            guard let data = try await store.read(account: credentialCacheAccount) else {
                return []
            }
            return NextTransportRelayCredentialCachePolicy.decode(data)
        } catch {
            mobileHostNextTransportLog.error(
                """
                host relay credential cache read failed \
                error=\(String(describing: error), privacy: .public); starting uncached
                """)
            return []
        }
    }

    private nonisolated static func persistCachedRelayCredentials(
        _ entries: [NextTransportCachedRelayCredential]
    ) async {
        guard !entries.isEmpty,
            let data = NextTransportRelayCredentialCachePolicy.encode(entries)
        else { return }
        do {
            try await CmxIrohKeychainCredentialStore(service: credentialCacheService)
                .write(
                    data, account: credentialCacheAccount,
                    accessibility: .afterFirstUnlockThisDeviceOnly)
        } catch {
            mobileHostNextTransportLog.error(
                """
                host relay credential cache write failed \
                error=\(String(describing: error), privacy: .public); next launch mints fresh
                """)
        }
    }

    // MARK: - Broker client

    /// Staging broker credentials from the dev dogfood env when present;
    /// nil (direct-only host) otherwise. Reads the same secrets file the
    /// dogfood tooling provisions — nonisolated, and constructed off the
    /// main actor by start(), because that read is file I/O.
    private nonisolated static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"] ?? Self.secretsValue("CMUX_DOGFOOD_STACK_EMAIL"),
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
                ?? Self.secretsValue("CMUX_DOGFOOD_STACK_PASSWORD")
        else { return nil }
        return BrokerCredentialClient(
            environment: .staging,
            identity: identity,
            auth: .password(email: email, password: password),
            tag: "next-transport-host",
            platform: "mac")
    }

    private nonisolated static func secretsValue(_ key: String) -> String? {
        let path = ("~/.secrets/cmuxterm-dev.env" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}

#endif

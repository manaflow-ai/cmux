#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
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

/// Graduation P4 slice 2: the cmux-lite-proven transport running as a
/// PARALLEL host inside the real Mac app — its own iroh endpoint, its own
/// ALPN (`cmux/peer/1`), its own relay registration with zero-gap
/// credential rotation — while CmuxIrohTransport continues to serve every
/// existing client untouched. Dev-gated: builds only in DEBUG and starts
/// only when the debug default is on. No production surface changes until
/// the E1 compat verdict (manaflow-ai/cmuxterm-hq#317, TRANSPORT-CONTRACT
/// v16 D7).
///
/// What it serves today is the transport contract's proof surface: real
/// admission (grant verification against the embedded dev signer), the echo
/// lane, and the chat fan-out — enough for an iOS dev build to dial through
/// staging relays and exercise session lifecycle end to end. Terminal lanes
/// arrive with the router slice.
@MainActor
@Observable
final class MobileHostNextTransportRuntime {
    static let shared = MobileHostNextTransportRuntime()

    /// Debug toggle (mirrors CmxIrohTransportVerificationMode's pattern).
    static let debugDefaultsKey = "dev.cmux.nextTransport.enabled"

    private(set) var state: String = "off"
    private(set) var endpointID: String?
    private(set) var relayURL: String?
    private(set) var admissions = 0

    private var endpoint: Endpoint?
    private var host: TransportHost?
    private var signer: GrantSigner?
    private var acceptTask: Task<Void, Never>?
    private var renewTask: Task<Void, Never>?
    private var credentialClient: BrokerCredentialClient?

    /// Default ON in dev builds: the parallel host is how a dev Mac
    /// advertises next-transport support to probing phones. The Debug menu
    /// toggle remains the kill switch.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.debugDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.debugDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        mobileHostNextTransportLog.notice(
            "host runtime setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))")
        UserDefaults.standard.set(enabled, forKey: Self.debugDefaultsKey)
        Task { enabled ? await start() : await stop() }
    }

    func startIfEnabled() {
        guard isEnabled else {
            mobileHostNextTransportLog.notice("host runtime startIfEnabled: disabled; not starting")
            return
        }
        Task { await start() }
    }

    /// The dial ticket an iOS dev build needs: host key + relay, the same
    /// shape the lab's hostd emits. Published through the debug socket
    /// (next_transport_ticket) so tooling can hand it to the phone.
    var ticketJSON: String? {
        guard let endpoint, let signer else {
            mobileHostNextTransportLog.notice(
                """
                ticket mint refused: host not running \
                (endpoint=\(self.endpoint != nil, privacy: .public) \
                signer=\(self.signer != nil, privacy: .public) \
                state=\(self.state, privacy: .public))
                """)
            return nil
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
        guard let data = try? JSONEncoder().encode(JSONValue.object(ticket)) else {
            mobileHostNextTransportLog.error("ticket mint failed: ticket JSON did not encode")
            return nil
        }
        mobileHostNextTransportLog.notice(
            """
            ticket minted endpoint=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
            addrs=\(addrs.joined(separator: ","), privacy: .public) \
            relay=\(self.relayURL ?? "none", privacy: .public)
            """)
        return String(data: data, encoding: .utf8)
    }

    /// Mint a grant for a dialing device (dev flow: the embedded signer
    /// stands in for the pairing broker, exactly as in the lab's hostd).
    func mintGrant(deviceID: String, devicePublicKey: Data, appIdentity: String) -> String? {
        guard let signer else {
            mobileHostNextTransportLog.notice(
                """
                grant mint refused: no signer (host not running) \
                device=\(String(deviceID.prefix(8)), privacy: .public) \
                state=\(self.state, privacy: .public)
                """)
            return nil
        }
        guard
            let grant = try? signer.mint(
                accountID: "acct-dev", deviceID: deviceID,
                devicePublicKey: devicePublicKey, appIdentity: appIdentity,
                grantID: "g-dev-\(UUID().uuidString.prefix(8))",
                issuedAt: Int64(Date().timeIntervalSince1970)),
            let data = try? JSONEncoder().encode(JSONValue.object(["grant": grant.payloadValue]))
        else {
            mobileHostNextTransportLog.error(
                """
                grant mint FAILED device=\(String(deviceID.prefix(8)), privacy: .public) \
                app=\(appIdentity, privacy: .public)
                """)
            return nil
        }
        mobileHostNextTransportLog.notice(
            """
            grant minted device=\(String(deviceID.prefix(8)), privacy: .public) \
            app=\(appIdentity, privacy: .public) \
            grantID=\(grant.grantID, privacy: .public) \
            key=\(devicePublicKey.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
            """)
        return String(data: data, encoding: .utf8)
    }

    private func start() async {
        guard endpoint == nil else {
            mobileHostNextTransportLog.notice(
                "host start skipped: already running state=\(self.state, privacy: .public)")
            return
        }
        let startClock = ContinuousClock.now
        state = "starting"
        mobileHostNextTransportLog.notice("host start begin state=starting")
        do {
            // Identity: stable per install, separate from the legacy
            // transport's identity (parallel hosts, parallel keys).
            let identity = Self.loadOrCreateIdentity()
            // The signer persists like the identity: a fresh key per launch
            // would invalidate every previously minted phone grant on every
            // Mac restart, forcing phones through re-credentialing.
            let signerKeyKey = "dev.cmux.nextTransport.signer.key"
            let signer: GrantSigner
            if let stored = UserDefaults.standard.string(forKey: signerKeyKey),
                let keyData = Data(base64Encoded: stored)
            {
                signer = GrantSigner(privateKeyData: keyData)
                mobileHostNextTransportLog.notice(
                    """
                    host signer LOADED (persisted; prior phone grants stay valid) \
                    signerKey=\(signer.publicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
                    """)
            } else {
                signer = GrantSigner()
                UserDefaults.standard.set(
                    signer.privateKeyData.base64EncodedString(), forKey: signerKeyKey)
                mobileHostNextTransportLog.notice(
                    """
                    host signer CREATED (fresh; any previously minted phone grants \
                    are now invalid) \
                    signerKey=\(signer.publicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined(), privacy: .public)
                    """)
            }
            self.signer = signer
            let host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
            self.host = host

            // Staging credentials via the same self-minting client the
            // phone proved in the lab; relay catalog, rendezvous-first.
            let client = Self.brokerClient(identity: identity)
            credentialClient = client
            mobileHostNextTransportLog.notice(
                """
                host broker client \(client == nil ? "ABSENT (no dogfood credentials; direct-only)" : "ready", privacy: .public) \
                device=\(String(identity.deviceID.prefix(8)), privacy: .public)
                """)
            var relays: [IrohSubstrate.RelayAccess] = []
            if let client {
                let mintStart = ContinuousClock.now
                let credentials = try await client.mint(preferredUrl: nil)
                relays = credentials.map {
                    IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                }
                relayURL = credentials.first?.relayUrl
                mobileHostNextTransportLog.notice(
                    """
                    host relay credentials minted count=\(credentials.count, privacy: .public) \
                    first=\(self.relayURL ?? "none", privacy: .public) \
                    elapsedMs=\(mobileHostNextTransportElapsedMs(since: mintStart), privacy: .public)
                    """)
            }
            let endpoint = try await (relays.isEmpty
                ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                : IrohSubstrate.endpoint(identity: identity, relays: relays))
            if !relays.isEmpty { await endpoint.online() }
            self.endpoint = endpoint
            endpointID = endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined()
            mobileHostNextTransportLog.notice(
                """
                host endpoint bound id=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
                relays=\(relays.count, privacy: .public) \
                sockets=\(endpoint.boundSockets().joined(separator: ","), privacy: .public)
                """)

            acceptTask = Task { [weak self] in
                var accepted = 0
                while let connection = try? await IrohSubstrate.acceptOne(endpoint: endpoint) {
                    guard let self else { return }
                    accepted += 1
                    let acceptedCount = accepted
                    let now = Int64(Date().timeIntervalSince1970)
                    mobileHostNextTransportLog.notice(
                        """
                        host accept-loop connection #\(acceptedCount, privacy: .public) \
                        serving now=\(now, privacy: .public)
                        """)
                    await host.serve(connection: connection, now: now)
                    await MainActor.run { self.admissions = self.admissions &+ 1 }
                    // Router slice: an admitted connection gets the full
                    // legacy application service (control RPC, lane router,
                    // server events) bridged over its raw streams.
                    if let admitted = await host.activeSession(for: connection) {
                        mobileHostNextTransportLog.notice(
                            """
                            host accept-loop connection #\(acceptedCount, privacy: .public) \
                            ADMITTED session=\(admitted.id, privacy: .public) \
                            device=\(String(admitted.grant.deviceID.prefix(8)), privacy: .public); \
                            starting bridge
                            """)
                        Task {
                            await MobileHostNextTransportBridge.run(
                                connection: connection,
                                grant: admitted.grant,
                                deviceKey: admitted.deviceKey)
                        }
                    } else {
                        mobileHostNextTransportLog.notice(
                            """
                            host accept-loop connection #\(acceptedCount, privacy: .public) \
                            NOT admitted (denied or closed during serve); no bridge
                            """)
                    }
                }
                mobileHostNextTransportLog.notice(
                    "host accept-loop exit (endpoint closed or accept failed)")
            }
            renewTask = Task { [weak self] in
                // Zero-gap rotation on the token's own cadence (refreshAfter
                // = 60s before the 300s expiry), insert-alone handoff.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(240))
                    guard let self, let client = self.credentialClient else { return }
                    do {
                        let fresh = try await client.mint(preferredUrl: self.relayURL)
                        for credential in fresh {
                            try await endpoint.insertRelay(
                                config: RelayConfig(
                                    url: credential.relayUrl, authToken: credential.token))
                        }
                        mobileHostNextTransportLog.notice(
                            """
                            host relay credentials rotated zero-gap \
                            count=\(fresh.count, privacy: .public) \
                            first=\(fresh.first?.relayUrl ?? "none", privacy: .public)
                            """)
                    } catch {
                        mobileHostNextTransportLog.error(
                            "credential rotation failed: \(String(describing: error))")
                    }
                }
            }
            state = relays.isEmpty ? "ready (direct only)" : "ready (relay)"
            publishPresenceRoute()
            mobileHostNextTransportLog.notice(
                """
                next-transport host up: \(self.endpointID ?? "?", privacy: .public) \
                state=\(self.state, privacy: .public) \
                elapsedMs=\(mobileHostNextTransportElapsedMs(since: startClock), privacy: .public)
                """)
        } catch {
            state = "failed: \(error)"
            mobileHostNextTransportLog.error(
                """
                next-transport start failed: \(String(describing: error), privacy: .public) \
                elapsedMs=\(mobileHostNextTransportElapsedMs(since: startClock), privacy: .public)
                """)
        }
    }

    /// Graduation slice 3: advertise the parallel host through the existing
    /// presence `routes` field. The route is identity + relay only (private
    /// addresses never enter presence), rides the same status pipeline as the
    /// iroh route so heartbeats pick it up automatically, and is facade-only:
    /// old clients drop the unknown kind at their failable-decode boundaries
    /// and no legacy selection/dial path treats it as a candidate.
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

    private func stop() async {
        mobileHostNextTransportLog.notice(
            """
            host stop begin state=\(self.state, privacy: .public) \
            endpoint=\(String(self.endpointID?.prefix(8) ?? "none"), privacy: .public)
            """)
        acceptTask?.cancel()
        renewTask?.cancel()
        MobileHostService.shared.updateNextTransportRoute(nil)
        mobileHostNextTransportLog.notice("presence route CLEARED")
        try? await endpoint?.close()
        endpoint = nil
        host = nil
        signer = nil
        credentialClient = nil
        endpointID = nil
        relayURL = nil
        state = "off"
        mobileHostNextTransportLog.notice("host stop done state=off")
    }

    private static func loadOrCreateIdentity() -> PeerIdentity {
        let defaults = UserDefaults.standard
        let keyKey = "dev.cmux.nextTransport.identity.key"
        let idKey = "dev.cmux.nextTransport.identity.deviceID"
        if let keyB64 = defaults.string(forKey: keyKey),
            let key = Data(base64Encoded: keyB64),
            let deviceID = defaults.string(forKey: idKey)
        {
            mobileHostNextTransportLog.notice(
                "host identity LOADED device=\(String(deviceID.prefix(8)), privacy: .public)")
            return PeerIdentity(
                appIdentity: "dev.cmux.next.host", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.host", deviceID: UUID().uuidString.lowercased())
        defaults.set(fresh.privateKeyData.base64EncodedString(), forKey: keyKey)
        defaults.set(fresh.deviceID, forKey: idKey)
        mobileHostNextTransportLog.notice(
            "host identity CREATED device=\(String(fresh.deviceID.prefix(8)), privacy: .public)")
        return fresh
    }

    /// Staging broker credentials from the dev dogfood env when present;
    /// nil (direct-only host) otherwise. Reads the same secrets file the
    /// dogfood tooling provisions.
    private static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"] ?? Self.secretsValue("CMUX_DOGFOOD_STACK_EMAIL"),
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
                ?? Self.secretsValue("CMUX_DOGFOOD_STACK_PASSWORD")
        else { return nil }
        return BrokerCredentialClient(
            config: BrokerCredentialClient.Config(
                baseUrl: "https://cmux-staging.vercel.app",
                stackBase: "https://api.stack-auth.com",
                stackProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
                stackPck: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
                email: email, password: password,
                deviceId: identity.deviceID,
                appInstanceId: identity.deviceID,
                tag: "next-transport-host", platform: "mac"),
            identity: identity)
    }

    private static func secretsValue(_ key: String) -> String? {
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

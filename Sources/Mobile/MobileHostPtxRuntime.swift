#if DEBUG
import CMUXMobileCore
import CryptoKit
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxPeerTransport
import Foundation
import IrohLib
import Observation
import OSLog

let mobileHostPtxLog = Logger(
    subsystem: "dev.cmux",
    category: "peer-transport"
)

/// Peer transport v2: the from-scratch phone↔Mac transport
/// (CmuxPeerTransport) running as a PARALLEL host inside the real Mac app —
/// its own iroh endpoint, its own ALPN (`cmux/ptx/1`), its own relay
/// registration with zero-gap credential rotation — while CmuxIrohTransport
/// continues to serve every existing client untouched. Dev-gated: builds
/// only in DEBUG and starts only while the debug default stays on.
///
/// Every admitted connection is handed to ``MobileHostPtxBridge``, which runs
/// the full legacy application service (control RPC, lane router, server
/// events) over the new transport's raw streams.
@MainActor
@Observable
final class MobileHostPtxRuntime {
    static let shared = MobileHostPtxRuntime()

    /// Kill switch; absent means ON in dev builds.
    static let enabledDefaultsKey = "dev.cmux.ptx.enabled"
    /// The endpoint identity key MUST persist: losing it changes the Mac's
    /// endpoint ID and orphans every phone's stored ticket.
    static let identityDefaultsKey = "dev.cmux.ptx.host.identity"
    /// The grant signer MUST persist: a fresh signer invalidates every
    /// phone's stored grant on the next admission.
    static let signerDefaultsKey = "dev.cmux.ptx.host.signer"
    static let appInstanceIDDefaultsKey = "dev.cmux.ptx.host.appInstanceID"
    static let credentialCacheDefaultsKey = "dev.cmux.ptx.host.relayCredentials"

    /// The (device, app) identity the host presents to the broker and bakes
    /// into tickets. Distinct from the legacy transport's identity.
    private static let hostAppIdentity = "dev.cmux.ptx.host"

    private(set) var state = "off"
    private(set) var endpointIDHex: String?
    private(set) var relayURL: String?
    private(set) var admissions = 0
    /// Short human strings for the status verb; the authoritative record is
    /// the PtxEventLog JSONL file.
    private(set) var lastEvents: [String] = []

    private weak var auth: AuthCoordinator?
    private var endpointBox: IrohEndpointBox?
    private var host: PtxHost?
    private var credentialService: PtxCredentialService?
    private var eventLog: PtxEventLog?
    private var identityWasPersisted = false
    private var signerWasPersisted = false

    /// Default ON in dev builds: the parallel host is how a dev Mac serves
    /// v2-dialing phones. The defaults key remains the kill switch.
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        mobileHostPtxLog.notice(
            "runtime setEnabled=\(enabled, privacy: .public) (was \(self.isEnabled, privacy: .public))"
        )
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        Task { enabled ? await self.start() : await self.stop() }
    }

    /// Inject the auth dependency. Called from the same composition root
    /// that configures the legacy mobile host.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    func startIfEnabled() {
        guard isEnabled else {
            mobileHostPtxLog.notice("runtime startIfEnabled: disabled; not starting")
            return
        }
        Task { await self.start() }
    }

    private func start() async {
        guard host == nil else {
            mobileHostPtxLog.notice(
                "runtime start skipped: already running state=\(self.state, privacy: .public)"
            )
            return
        }
        state = "starting"
        let log = PtxEventLog(
            subsystem: "dev.cmux",
            category: "peer-transport",
            fileURL: Self.eventLogURL()
        )
        eventLog = log

        let defaults = UserDefaults.standard
        // Endpoint identity, broker registration, and credentials are all
        // ACCOUNT-scoped, like the legacy transport's keychain repositories:
        // relay tokens are only minted for endpoints bound under the calling
        // account, so an account switch (the sim-leg agent/personal seesaw
        // re-arms the Mac between accounts) needs its own identity. The
        // launcher relaunches the app to switch accounts, so resolving the
        // scope once at start is sufficient; the grant signer stays global so
        // phone grants survive the seesaw.
        let scope = await resolveAccountScope()
        let identityKey = Self.identityDefaultsKey + "." + scope
        identityWasPersisted = defaults.data(forKey: identityKey) != nil
        let identity = PtxIdentityStore.loadOrCreate(
            defaults: defaults,
            key: identityKey,
            deviceID: cmxCanonicalDeviceID(MobileHostIdentity.deviceID()),
            appIdentity: Self.hostAppIdentity
        )
        signerWasPersisted = defaults.data(forKey: Self.signerDefaultsKey) != nil
        let signer = PtxGrantSigner.loadOrCreate(
            defaults: defaults,
            key: Self.signerDefaultsKey
        )
        mobileHostPtxLog.notice(
            """
            runtime identity \(self.identityWasPersisted ? "LOADED" : "CREATED", privacy: .public) \
            endpoint=\(String(identity.endpointIDHex.prefix(8)), privacy: .public); \
            signer \(self.signerWasPersisted
                ? "LOADED (prior phone grants stay valid)"
                : "CREATED (any previously minted phone grants are now invalid)", privacy: .public) \
            key=\(PtxEventLog.hex8(signer.publicKeyData), privacy: .public)
            """
        )

        // Same broker origin and account/session source as the legacy Mac
        // host: the live Stack session serves a coherent (access, refresh)
        // pair per request, so sign-out fails v2 minting closed on the next
        // request, and a configure() that lands after start() still serves.
        let broker = PtxBrokerClient(
            baseURL: AuthEnvironment.irohBrokerBaseURL?.absoluteString
                ?? "https://cmux-staging.vercel.app",
            auth: .tokens {
                guard let auth = await MobileHostPtxRuntime.shared.auth else {
                    throw PtxBrokerError.shape("no signed-in account")
                }
                let session = try await auth.authenticatedSessionSnapshot()
                return (access: session.accessToken, refresh: session.refreshToken)
            },
            identity: identity,
            appInstanceID: Self.persistedAppInstanceID(defaults: defaults),
            tag: MobileHostIdentity.instanceTag(),
            platform: "mac"
        )
        let credentials = PtxCredentialService(
            broker: broker,
            defaults: defaults,
            cacheKey: Self.credentialCacheDefaultsKey + "." + scope,
            log: log
        )
        credentialService = credentials

        // Boot fast on valid cached credentials; mint fresh otherwise. A
        // failed mint (offline, signed out) boots the endpoint direct/LAN
        // only, and the renew loop heals relays when the broker returns.
        var boot = await credentials.validCachedCredentials()
        if boot.isEmpty {
            boot = (try? await credentials.freshCredentials()) ?? []
        }
        do {
            // Bind with ONLY the primary (home) relay credential: seeding the
            // relay map with the whole minted fleet makes the FFI bind()
            // itself time out (~30s) against the live staging fleet, while a
            // single home relay establishes in well under a second. The renew
            // loop rotates this one relay in place (insertRelay alone).
            let endpoint = try await PtxEndpoint.bind(
                identity: identity,
                relays: boot.prefix(1).map {
                    PtxEndpoint.RelayAccess(url: $0.relayURL, authToken: $0.token)
                }
            )
            if !boot.isEmpty {
                _ = await PtxEndpoint.onlineWithin(endpoint: endpoint, seconds: 10)
            }
            let box = IrohEndpointBox(endpoint: endpoint)
            endpointBox = box
            endpointIDHex = identity.endpointIDHex
            relayURL = boot.first?.relayURL
            let host = PtxHost(
                identity: identity,
                signer: signer,
                log: log,
                onAdmitted: { [weak self] session in
                    await MainActor.run {
                        guard let self else { return }
                        self.admissions += 1
                        self.noteEvent(
                            "admitted \(session.sessionID) device=\(session.grant.deviceID.prefix(8))"
                        )
                    }
                    // The bridge runs for the session's lifetime; spawning it
                    // keeps the host's admission pipeline unblocked.
                    Task { await MobileHostPtxBridge.run(session: session) }
                },
                onSessionEnded: { [weak self] session, cause in
                    await MainActor.run {
                        self?.noteEvent(
                            "ended \(session.sessionID) cause=\(cause ?? "unattributed")"
                        )
                    }
                }
            )
            self.host = host
            await host.serve(endpoint: box)
            await credentials.startRenewLoop(
                endpoint: box,
                preferredRelayURL: boot.first?.relayURL
            )
            state = boot.isEmpty ? "ready (direct only)" : "ready (relay)"
            mobileHostPtxLog.notice(
                """
                peer transport v2 host up endpoint=\(String(identity.endpointIDHex.prefix(8)), privacy: .public) \
                relay=\(self.relayURL ?? "none", privacy: .public) \
                state=\(self.state, privacy: .public)
                """
            )
        } catch {
            state = "failed: \(error)"
            mobileHostPtxLog.error(
                "peer transport v2 start failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func stop() async {
        mobileHostPtxLog.notice(
            """
            runtime stop begin state=\(self.state, privacy: .public) \
            endpoint=\(String(self.endpointIDHex?.prefix(8) ?? "none"), privacy: .public)
            """
        )
        await credentialService?.stopRenewLoop()
        await host?.stop()
        try? await endpointBox?.endpoint.close()
        endpointBox = nil
        host = nil
        credentialService = nil
        eventLog = nil
        endpointIDHex = nil
        relayURL = nil
        state = "off"
        mobileHostPtxLog.notice("runtime stop done state=off")
    }

    /// Everything a phone needs to dial this Mac, as the encoded ticket
    /// string the pair RPC and the soak harness hand to the phone. Direct
    /// addresses are the Mac's real LAN interface IPs; loopback rewrites of
    /// the wildcard bound socket are dialable only from this machine and
    /// never enter a ticket.
    func ticketEncoded() async -> String? {
        guard let host, let endpointBox else {
            mobileHostPtxLog.notice(
                "ticket mint refused: host not running state=\(self.state, privacy: .public)"
            )
            return nil
        }
        let ticket = await host.ticket(
            relayURL: relayURL,
            lanAddresses: Self.lanAddresses(endpoint: endpointBox.endpoint)
        )
        guard let encoded = try? ticket.encoded() else {
            mobileHostPtxLog.error("ticket mint failed: ticket did not encode")
            return nil
        }
        mobileHostPtxLog.notice(
            """
            ticket minted endpoint=\(String(self.endpointIDHex?.prefix(8) ?? "?"), privacy: .public) \
            relay=\(self.relayURL ?? "none", privacy: .public)
            """
        )
        return encoded
    }

    /// Mints a grant for a dialing device, bound to the signed-in account
    /// (the same source that authorizes the broker tokens). Returns the
    /// base64 of the JSON-encoded grant.
    func mintGrantEncoded(
        deviceID: String, devicePublicKey: Data, appIdentity: String
    ) async -> String? {
        guard let host else {
            mobileHostPtxLog.notice(
                "grant mint refused: host not running state=\(self.state, privacy: .public)"
            )
            return nil
        }
        guard let account = accountIdentity() else {
            mobileHostPtxLog.notice("grant mint refused: no signed-in account")
            return nil
        }
        guard
            let grant = try? await host.mintGrant(
                account: account,
                deviceID: deviceID,
                devicePublicKey: devicePublicKey,
                appIdentity: appIdentity
            ),
            let data = try? JSONEncoder().encode(grant)
        else {
            mobileHostPtxLog.error(
                "grant mint FAILED device=\(String(deviceID.prefix(8)), privacy: .public)"
            )
            return nil
        }
        mobileHostPtxLog.notice(
            """
            grant minted device=\(String(deviceID.prefix(8)), privacy: .public) \
            app=\(appIdentity, privacy: .public) grantID=\(grant.grantID, privacy: .public)
            """
        )
        return data.base64EncodedString()
    }

    /// One JSON object for the `ptx-status` socket verb.
    func statusJSON() async -> String {
        let defaults = UserDefaults.standard
        let sessions = await host?.activeSessionCount() ?? 0
        let payload: [String: Any] = [
            "enabled": isEnabled,
            "endpoint_id": endpointIDHex ?? "",
            "relay_url": relayURL ?? "",
            "sessions": sessions,
            "identity_persisted": host != nil
                ? identityWasPersisted
                : defaults.data(forKey: Self.identityDefaultsKey) != nil,
            "signer_persisted": host != nil
                ? signerWasPersisted
                : defaults.data(forKey: Self.signerDefaultsKey) != nil,
            "state": state,
            "admissions": admissions,
            "last_events": lastEvents,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        else {
            return #"{"error":"status did not encode"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func noteEvent(_ line: String) {
        lastEvents.append(line)
        if lastEvents.count > 8 {
            lastEvents.removeFirst(lastEvents.count - 8)
        }
    }

    private func accountIdentity() -> String? {
        guard let user = auth?.currentUser else { return nil }
        if let email = user.primaryEmail, !email.isEmpty { return email }
        return user.id
    }

    /// Stable per-account key suffix, polled briefly because session restore
    /// races app startup. "signed-out" is a real scope: its broker calls fail
    /// closed until sign-in, and the next relaunch lands on the account scope.
    private func resolveAccountScope() async -> String {
        for _ in 0..<40 {
            if let account = accountIdentity() {
                let digest = SHA256.hash(data: Data(account.lowercased().utf8))
                return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "signed-out"
    }

    /// Real LAN interface IPs carrying the bound v4 port. Bound sockets
    /// report the wildcard (0.0.0.0:port); a loopback rewrite of that is
    /// dialable only from this Mac, so tickets carry interface IPs instead.
    private static func lanAddresses(endpoint: IrohLib.Endpoint) -> [String] {
        let bound = endpoint.boundSockets()
        guard
            let v4Port = bound.first(where: { $0.contains(".") })?
                .split(separator: ":").last
        else { return [] }
        let interfaces =
            (try? CmxIrohSystemLANInterfaceSnapshotProvider().interfaceAddresses()) ?? []
        return interfaces
            .filter { $0.family == .ipv4 }
            .map { "\($0.ipAddress):\(v4Port)" }
    }

    private static func persistedAppInstanceID(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: appInstanceIDDefaultsKey),
            !stored.isEmpty {
            return stored
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: appInstanceIDDefaultsKey)
        return fresh
    }

    /// One JSONL timeline per bundle identity (tagged dev builds must not
    /// interleave appends in one file), under the app's Application Support.
    private static func eventLogURL() -> URL {
        let rawScope = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.debug"
        let scope = String(
            rawScope.map { character in
                character.isASCII
                    && (character.isLetter
                        || character.isNumber
                        || ["-", ".", "_"].contains(character))
                    ? character
                    : "_"
            }
        )
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("cmux", isDirectory: true)
        .appendingPathComponent("ptx", isDirectory: true)
        .appendingPathComponent(scope, isDirectory: true)
        .appendingPathComponent("ptx-events.jsonl")
    }
}
#endif

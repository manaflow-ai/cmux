#if DEBUG
import CmuxNextTransport
import Foundation
import OSLog

let mobileHostNextTransportLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-next-transport"
)

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

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.debugDefaultsKey)
        Task { enabled ? await start() : await stop() }
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        Task { await start() }
    }

    /// The dial ticket an iOS dev build needs: host key + relay, the same
    /// shape the lab's hostd emits. Published through the debug socket
    /// (next_transport_ticket) so tooling can hand it to the phone.
    var ticketJSON: String? {
        guard let endpoint, let signer else { return nil }
        let addrs = endpoint.boundSockets().map {
            $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        var ticket: [String: JSONValue] = [
            "key": .data(endpoint.id().toBytes()),
            "serverKey": .data(signer.publicKeyData),
            "addrs": .array(addrs.map { .string($0) }),
        ]
        if let relayURL { ticket["relay"] = .string(relayURL) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(ticket)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Mint a grant for a dialing device (dev flow: the embedded signer
    /// stands in for the pairing broker, exactly as in the lab's hostd).
    func mintGrant(deviceID: String, devicePublicKey: Data, appIdentity: String) -> String? {
        guard let signer else { return nil }
        guard
            let grant = try? signer.mint(
                accountID: "acct-dev", deviceID: deviceID,
                devicePublicKey: devicePublicKey, appIdentity: appIdentity,
                grantID: "g-dev-\(UUID().uuidString.prefix(8))",
                issuedAt: Int64(Date().timeIntervalSince1970)),
            let data = try? JSONEncoder().encode(JSONValue.object(["grant": grant.payloadValue]))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func start() async {
        guard endpoint == nil else { return }
        state = "starting"
        do {
            // Identity: stable per install, separate from the legacy
            // transport's identity (parallel hosts, parallel keys).
            let identity = Self.loadOrCreateIdentity()
            let signer = GrantSigner()
            self.signer = signer
            let host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
            self.host = host

            // Staging credentials via the same self-minting client the
            // phone proved in the lab; relay catalog, rendezvous-first.
            let client = Self.brokerClient(identity: identity)
            credentialClient = client
            var relays: [IrohSubstrate.RelayAccess] = []
            if let client {
                let credentials = try await client.mint(preferredUrl: nil)
                relays = credentials.map {
                    IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                }
                relayURL = credentials.first?.relayUrl
            }
            let endpoint = try await (relays.isEmpty
                ? IrohSubstrate.endpoint(identity: identity, minimalLoopback: false)
                : IrohSubstrate.endpoint(identity: identity, relays: relays))
            if !relays.isEmpty { await endpoint.online() }
            self.endpoint = endpoint
            endpointID = endpoint.id().toBytes().map { String(format: "%02x", $0) }.joined()

            acceptTask = Task { [weak self] in
                while let connection = try? await IrohSubstrate.acceptOne(endpoint: endpoint) {
                    guard let self else { return }
                    let now = Int64(Date().timeIntervalSince1970)
                    await host.serve(connection: connection, now: now)
                    await MainActor.run { self.admissions = self.admissions &+ 1 }
                }
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
                        mobileHostNextTransportLog.info("relay credentials rotated zero-gap")
                    } catch {
                        mobileHostNextTransportLog.error(
                            "credential rotation failed: \(String(describing: error))")
                    }
                }
            }
            state = relays.isEmpty ? "ready (direct only)" : "ready (relay)"
            mobileHostNextTransportLog.info(
                "next-transport host up: \(self.endpointID ?? "?", privacy: .public)")
        } catch {
            state = "failed: \(error)"
            mobileHostNextTransportLog.error(
                "next-transport start failed: \(String(describing: error))")
        }
    }

    private func stop() async {
        acceptTask?.cancel()
        renewTask?.cancel()
        try? await endpoint?.close()
        endpoint = nil
        host = nil
        signer = nil
        credentialClient = nil
        endpointID = nil
        relayURL = nil
        state = "off"
    }

    private static func loadOrCreateIdentity() -> PeerIdentity {
        let defaults = UserDefaults.standard
        let keyKey = "dev.cmux.nextTransport.identity.key"
        let idKey = "dev.cmux.nextTransport.identity.deviceID"
        if let keyB64 = defaults.string(forKey: keyKey),
            let key = Data(base64Encoded: keyB64),
            let deviceID = defaults.string(forKey: idKey)
        {
            return PeerIdentity(
                appIdentity: "dev.cmux.next.host", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.host", deviceID: UUID().uuidString.lowercased())
        defaults.set(fresh.privateKeyData.base64EncodedString(), forKey: keyKey)
        defaults.set(fresh.deviceID, forKey: idKey)
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

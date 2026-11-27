import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

// Defects from the H7 walkthrough (2026-10-20). Settings › Devices froze the
// app for 8-20 s at a time: its state getter read each relay's secret from
// the Keychain on the main actor. Ask for Access could not raise a View Only
// Mac's access: the hub refused instead of asking the host.

nonisolated private struct KeychainTestKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                           encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext)
    }
}

/// Counts every call; a Keychain stand-in.
nonisolated private final class CountingSecretStore: RelaySecretStore, @unchecked Sendable {
    // @unchecked: `count` behind `lock`; the secrets are a MemoryRelaySecretStore.
    private let lock = NSLock()
    private var count = 0
    let store = MemoryRelaySecretStore()

    var calls: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    private func bump() { lock.withLock { count += 1 } }

    func secret(relayID: String) -> RelaySecret? { bump(); return store.secret(relayID: relayID) }
    func save(_ secret: RelaySecret, relayID: String) { bump(); store.save(secret, relayID: relayID) }
    func remove(relayID: String) { bump(); store.remove(relayID: relayID) }
    func relayIDs() -> [String] { bump(); return store.relayIDs() }
}

/// The hub's two answers this test needs, behind URLProtocol.
nonisolated private final class RelayListProtocol: URLProtocol, @unchecked Sendable {
    // @unchecked: `relays` is set once before any request.
    nonisolated(unsafe) static var relays = #"{"relays":[]}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = url.path == "/v1/auth/stack"
            ? #"{"session":"hub-session","userId":"u","expiresAt":4102444800000}"#
            : Self.relays
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct MacScreenDevicesKeychainTests {
    @Test func theStateGetterReadsNoSecretStore() async throws {
        let identity = DeviceIdentity(deviceID: UUID(), keys: KeychainTestKeys())
        let blob = try RelaySealing.seal(.sharedSecret("turn-secret"), relayID: "r1", to: identity.agreementKey)
        RelayListProtocol.relays = #"{"relays":[{"id":"r1","name":"Home","urls":["turns:home:5349"],"authMode":"shared_secret","sealed":{"\#(identity.id)":"\#(blob)"},"enabled":true,"priority":0},{"id":"r2","name":"Lab","urls":["turn:lab:3478"],"authMode":"static","sealed":{},"enabled":true,"priority":1}]}"#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayListProtocol.self]
        let client = DeviceHubClient(baseURL: try #require(URL(string: "https://hub.invalid")), identity: identity,
                                     tokens: DeviceHubAccountToken { "stack-token" }, session: URLSession(configuration: configuration))
        let secrets = CountingSecretStore()
        let hub = DeviceHub(client: client, secrets: secrets, deviceName: "Test Mac")
        await hub.refreshRelays()
        #expect(hub.relays.count == 2)

        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
        let settings = MacScreenDevicesSettings(pages: pages)
        pages.hubConfigured = true
        pages.hub = hub
        secrets.reset()
        let state = settings.state
        #expect(state.relays.map(\.hasSecret) == [true, false])
        #expect(secrets.calls == 0, "the state getter called the secret store \(secrets.calls) time(s)")
        pages.hub = nil
    }
}

@MainActor
struct MacScreenAskForAccessTests {
    /// Ask for Access › Full Control from a View Only Mac: the hub now asks the host
    /// (`pending`), so this Mac waits for the host's answer instead of showing a refusal.
    @Test func askingAboveTheSavedAccessWaitsForTheHost() {
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.phase = .requesting(.full)
        viewer.requestAnswered(.success(HubSession(id: "s1", state: .pending, scope: .full)), scope: .full, hub: nil)
        #expect(viewer.phase == .waitingForApproval(sessionID: "s1", scope: .full))
        // An older hub still refuses with scope_exceeds_permission: the View Only card.
        viewer.phase = .requesting(.full)
        viewer.requestAnswered(.failure(.server(status: 403, code: .scopeExceedsPermission, message: "")), scope: .full, hub: nil)
        #expect(viewer.phase == .refused(.scopeExceeds, requested: .full))
    }
}

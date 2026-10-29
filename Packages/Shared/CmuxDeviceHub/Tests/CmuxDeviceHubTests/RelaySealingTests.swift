@testable import CmuxDeviceHub
import Foundation
import Testing

@Suite struct RelaySealingTests {
    @Test func aSealedSecretOpensOnlyForItsDeviceAndRelay() throws {
        let mac = DeviceIdentity.software(), phone = DeviceIdentity.software("a1b2c3d4-0000-4000-8000-000000000001")
        let secret = RelaySecret.static(username: "alice", password: "s3cret")
        let blob = try RelaySealing.seal(secret, relayID: "relay-1", to: mac.agreementKey)
        #expect(try RelaySealing(identity: mac).open(blob, relayID: "relay-1") == secret)
        #expect(throws: (any Error).self) { try RelaySealing(identity: phone).open(blob, relayID: "relay-1") }
        #expect(throws: (any Error).self) { try RelaySealing(identity: mac).open(blob, relayID: "relay-2") }
        // The blob is the 65-byte encapsulated key, then the ciphertext.
        #expect((Data(base64Encoded: blob)?.count ?? 0) > 65)
    }

    @Test func sealingForDevicesCoversEveryDeviceWithAKey() throws {
        let mac = DeviceIdentity.software(), phone = DeviceIdentity.software("a1b2c3d4-0000-4000-8000-000000000001")
        let devices = [
            HubDevice(id: mac.id, name: "Mac", agreementKey: mac.agreementKey),
            HubDevice(id: phone.id, name: "Phone", agreementKey: phone.agreementKey),
            HubDevice(id: "no-key", name: "Old"),
        ]
        let sealed = try RelaySealing.seal(.sharedSecret("turn-secret"), relayID: "r", for: devices)
        #expect(Set(sealed.keys) == [mac.id, phone.id])
        #expect(try RelaySealing(identity: phone).open(sealed[phone.id]!, relayID: "r") == .sharedSecret("turn-secret"))
    }

    @Test func secretsEncodeWithAnExplicitMode() throws {
        let shared = String(decoding: try JSONEncoder().encode(RelaySecret.sharedSecret("k")), as: UTF8.self)
        #expect(shared.contains(#""mode":"shared_secret""#) && shared.contains(#""secret":"k""#))
        let decoded = try JSONDecoder().decode(RelaySecret.self, from: Data(#"{"mode":"static","username":"u","password":"p"}"#.utf8))
        #expect(decoded == .static(username: "u", password: "p"))
    }

    @Test func sharedSecretCredentialsFollowTheTURNRESTFormat() {
        let minted = RelaySealing.sharedSecretCredential(secret: "turn-secret", deviceName: "Studio Mac", now: fixedNow())
        // The label is TURN-safe: lowercase ASCII letters, digits and dashes.
        #expect(minted.username == "1800021600:studio-mac")
        // base64(HMAC-SHA1("turn-secret", username)), computed independently.
        #expect(minted.credential == "EFbsQ7RKPBB3PndEif3abGDgJLM=")
        #expect(minted.expires == Date(timeIntervalSince1970: 1_800_021_600))
    }

    @Test func iceServersCarryTheRelayURLsAndCredentials() {
        let relay = HubRelay(id: "r", name: "Home", urls: ["turn:home.example:3478", "turns:home.example:5349"], authMode: .static)
        let fixed = RelaySealing.iceServer(relay, secret: .static(username: "u", password: "p"), deviceName: "Mac", now: fixedNow())
        #expect(fixed == DeviceHubICEServer(urls: relay.urls, username: "u", credential: "p"))
        let minted = RelaySealing.iceServer(relay, secret: .sharedSecret("turn-secret"), deviceName: "Studio Mac", now: fixedNow())
        #expect(minted.username == "1800021600:studio-mac")
        #expect(minted.credential == "EFbsQ7RKPBB3PndEif3abGDgJLM=")
    }

    /// coturn refuses usernames with spaces or curly quotes, which every default macOS name has.
    @Test func relayLabelsAreSafeForTURN() {
        #expect(RelaySealing.relayLabel(deviceName: "cmux’s Mac mini (2)", deviceID: "6F1C2A4E-0D3B") == "cmuxs-mac-mini-2")
        #expect(RelaySealing.relayLabel(deviceName: "Zoë's MacBook Pro", deviceID: "x") == "zoes-macbook-pro")
        #expect(RelaySealing.relayLabel(deviceName: "  --  ", deviceID: "6F1C2A4E-0D3B-4C5A") == "6f1c2a4e")
        #expect(RelaySealing.relayLabel(deviceName: "日本語", deviceID: "") == "device")
        let long = RelaySealing.relayLabel(deviceName: String(repeating: "a", count: 80), deviceID: "")
        #expect(long.count == 32)
        let minted = RelaySealing.sharedSecretCredential(secret: "s", deviceName: "cmux’s Mac mini (2)", now: fixedNow())
        #expect(minted.username == "1800021600:cmuxs-mac-mini-2")
        #expect(minted.username.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ":") })
    }
}

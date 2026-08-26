import Foundation
import Testing

@testable import CmuxNextTransport

/// Live proof of self-minting (the production credential shape): the client
/// walks the REAL staging broker flow end to end and the issued token must
/// be bound to the minting identity's own key. Gated on a config file so the
/// default suite stays offline-clean.
/// Config: CMUX_LITE_BROKER_CONFIG -> JSON file with BrokerCredentialClient
/// .Config fields plus "identityPrivB64".
@Suite(
    "broker self-mint, live",
    .enabled(if: ProcessInfo.processInfo.environment["CMUX_LITE_BROKER_CONFIG"] != nil))
struct BrokerCredentialTests {
    @Test("Self-mint issues endpoint-bound credentials for the caller's key")
    func selfMintRoundTrip() async throws {
        let path = ProcessInfo.processInfo.environment["CMUX_LITE_BROKER_CONFIG"]!
        let raw = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let config = try JSONDecoder().decode(
            BrokerCredentialClient.Config.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let privB64 = raw.objectValue?["identityPrivB64"]?.stringValue,
            let priv = Data(base64Encoded: privB64)
        else {
            Issue.record("config missing identityPrivB64")
            return
        }
        let identity = PeerIdentity(
            appIdentity: "dev.cmux.lite", deviceID: config.deviceId, privateKeyData: priv)
        let client = BrokerCredentialClient(config: config, identity: identity)

        let credentials = try await client.mint(
            preferredUrl: "https://usc1.relay.cmux.dev/")
        #expect(!credentials.isEmpty)
        #expect(credentials.first?.relayUrl == "https://usc1.relay.cmux.dev/")
        for credential in credentials {
            #expect(
                IrohSubstrate.tokenEndpointId(credential.token) == identity.publicKeyData)
            if let exp = IrohSubstrate.tokenExpiry(credential.token) {
                #expect(exp > Int64(Date().timeIntervalSince1970))
            }
        }
        print("[broker-test] minted \(credentials.count) credentials, first for "
            + "\(credentials.first?.relayUrl ?? "?")")
    }
}

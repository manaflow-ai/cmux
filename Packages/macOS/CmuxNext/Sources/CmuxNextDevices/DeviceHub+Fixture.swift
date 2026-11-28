#if DEBUG
public import Foundation
import CryptoKit

/// A device hub that shows a given device list and talks to no server (DEBUG builds): the
/// `debug.device_hub` `fixture` action, for captures of Screen Sharing and Settings > Devices with
/// devices no capture machine has. It is never started: no registration, socket or request.
extension DeviceHub {
    public static func fixture(devices: [HubDevice]) -> DeviceHub {
        let identity = DeviceIdentity(deviceID: UUID(), keys: FixtureKeys())
        // `.invalid` never resolves (RFC 6761): a call that slipped through could reach no hub.
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid") ?? URL(fileURLWithPath: "/"), identity: identity,
                                     tokens: DeviceHubAccountToken { throw DeviceHubError.notSignedIn })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "This Mac")
        hub.showFixture(devices)
        return hub
    }
}

/// Throwaway keys for a fixture hub's identity: generated per fixture, kept in memory, never used to sign.
private struct FixtureKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { throw DeviceHubError.identity("fixture") }
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data { throw DeviceHubError.identity("fixture") }
}

#endif

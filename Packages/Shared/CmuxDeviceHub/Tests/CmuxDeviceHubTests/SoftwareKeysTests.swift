import CryptoKit
import Foundation
import Testing
@testable import CmuxDeviceHub

/// The iOS simulator's identity: software keys restored from what the
/// Keychain keeps sign what the hub verifies and open what relays seal to it.
@Suite struct SoftwareKeysTests {
    @Test func storedSoftwareKeysComeBackAsTheSameDevice() throws {
        let made = KeychainSoftwareDeviceKeys(signing: P256.Signing.PrivateKey(), agreement: P256.KeyAgreement.PrivateKey())
        let restored = try #require(KeychainSoftwareDeviceKeys(signingRaw: made.signingRaw, agreementRaw: made.agreementRaw))
        let identity = DeviceIdentity(deviceID: UUID(), keys: restored)
        #expect(identity.signingKey == DeviceIdentity(deviceID: UUID(), keys: made).signingKey)

        let message = Data("GET\n/v1/devices\n1800000000\n".utf8)
        let signature = try identity.sign(message).base64EncodedString()
        #expect(DeviceIdentity.verify(signature: signature, of: message, signingKey: identity.signingKey))

        let info = RelaySealing.info(relayID: "r1")
        var sender = try HPKE.Sender(recipientKey: made.agreementPublicKey, ciphersuite: RelaySealing.ciphersuite, info: info)
        let sealed = try sender.seal(Data("secret".utf8))
        #expect(try restored.open(sealed, encapsulatedKey: sender.encapsulatedKey, info: info) == Data("secret".utf8))
    }

    @Test func storedBytesThatAreNotKeysMakeANewDevice() {
        #expect(KeychainSoftwareDeviceKeys(signingRaw: Data([1, 2, 3]), agreementRaw: Data(count: 32)) == nil)
    }
}

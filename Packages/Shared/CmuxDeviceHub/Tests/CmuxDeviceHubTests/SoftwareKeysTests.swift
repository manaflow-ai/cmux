import CryptoKit
import Foundation
import Testing
@testable import CmuxDeviceHub

/// The iOS simulator's identity: software keys from the Keychain sign what the
/// hub verifies, and the same accounts give back the same device.
@Suite struct SoftwareKeysTests {
    @Test func softwareIdentitySignsVerifiablyAndReloadsTheSameDevice() throws {
        let keychain = DeviceKeychain(service: "dev.cmux.device-hub.tests.\(UUID().uuidString)")
        defer { for account in [DeviceIdentity.idAccount, DeviceIdentity.signingAccount, DeviceIdentity.agreementAccount] { try? keychain.delete(account) } }
        let first = try DeviceIdentity.loadSoftware(keychain: keychain)
        let message = Data("GET\n/v1/devices\n1800000000\n".utf8)
        let signature = try first.sign(message).base64EncodedString()
        #expect(DeviceIdentity.verify(signature: signature, of: message, signingKey: first.signingKey))
        let again = try DeviceIdentity.loadSoftware(keychain: keychain)
        #expect(again.id == first.id)
        #expect(again.signingKey == first.signingKey)
        #expect(again.agreementKey == first.agreementKey)
    }
}

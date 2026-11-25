import CmuxNextCompat
@testable import CmuxNextDevices
import Foundation
import Security
import Testing

/// Relay secrets live in the data-protection keychain, per bundle, like the app's other secrets.
struct DeviceKeychainTests {
    @Test func relaySecretsUseTheDataProtectionKeychainPerBundle() {
        let loginKeychain = LoginKeychain()
        let store = KeychainRelaySecretStore(bundleIdentifier: "com.example.tagged", loginKeychain: loginKeychain)
        #expect(store.keychain.service == "com.example.tagged.device-hub")
        #expect(store.keychain.dataProtection)
        let query = store.keychain.query("relay-r1")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "com.example.tagged.device-hub")
        // The device keys stay where they were made (moving them would make a new device).
        #expect(!DeviceKeychain(service: "s", loginKeychain: loginKeychain).dataProtection)
        #expect(DeviceKeychain(service: "s", loginKeychain: loginKeychain).query("a")[kSecUseDataProtectionKeychain as String] == nil)
    }
}

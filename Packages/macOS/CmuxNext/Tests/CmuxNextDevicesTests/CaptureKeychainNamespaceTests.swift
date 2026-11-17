import CmuxNextCompat
@testable import CmuxNextDevices
import Foundation
import Testing

struct CaptureKeychainNamespaceTests {
    @Test func invalidLeaseFailsBeforeTouchingSecurity() {
        let result = CaptureKeychainNamespace().prepare(bundleIdentifier: "com.example.capture",
                                                         leaseID: "not-a-lease", loginKeychain: LoginKeychain())
        #expect(result == DeviceHubCaptureCleanupResult(ok: false, code: .invalidLease))
    }

    @Test func partialIdentityRefusesPreparation() throws {
        let loginKeychain = LoginKeychain()
        let bundle = "com.example.capture.\(UUID().uuidString.lowercased())"
        let keychain = DeviceKeychain(service: bundle + ".device-hub", loginKeychain: loginKeychain)
        try keychain.write(Data("partial".utf8), account: "device-signing-key")
        defer { try? keychain.delete("device-signing-key") }

        let result = CaptureKeychainNamespace().prepare(bundleIdentifier: bundle, leaseID: "0123456789abcdef01234567",
                                                         loginKeychain: loginKeychain)
        #expect(result.code == .namespaceNotEmpty)
        #expect(!result.ok)
    }

    @Test func cleanupRequiresTheRunMarker() {
        let result = CaptureKeychainNamespace().cleanup(bundleIdentifier: "com.example.capture",
                                                         leaseID: "0123456789abcdef01234567", loginKeychain: LoginKeychain())
        #expect(result == DeviceHubCaptureCleanupResult(ok: false, code: .ownershipMissing))
    }
}

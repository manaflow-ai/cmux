import CryptoKit
@testable import CmuxNextDevices
import Foundation
import Security
import Testing

/// The device identity's items are login (file) Keychain items, where another build of the same
/// bundle id (the app after an update) may read an item but not delete or update it:
/// SecItemDelete and SecItemUpdate answer errSecInvalidOwnerEdit (-25244), as the install key
/// found (cmux#43592, probe cloud-signed-in-after-update-production, 2026-11-15). A renewal
/// (the hub refused the id: `device_removed`, `device_key_mismatch`) deleted the three items
/// first and threw, so an updated Mac could never become a new device again.
@Suite struct DeviceIdentityAcrossBuildsTests {
    /// The login Keychain as builds see it: every build reads every item; only the build that
    /// made one deletes it (an update is refused the same way; the identity never updates).
    final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: (data: Data, build: String)] = [:]

        func accounts() -> [String] { lock.withLock { Array(items.keys) } }
        func read(_ account: String) -> Data? { lock.withLock { items[account]?.data } }

        func add(_ data: Data, account: String, build: String) throws {
            try lock.withLock {
                guard items[account] == nil else { throw DeviceIdentity.Failure.keychain(errSecDuplicateItem) }
                items[account] = (data, build)
            }
        }

        func delete(_ account: String, build: String) -> OSStatus {
            lock.withLock {
                guard let item = items[account] else { return errSecItemNotFound }
                guard item.build == build else { return errSecInvalidOwnerEdit }
                items[account] = nil
                return errSecSuccess
            }
        }
    }

    /// One build's view of ``Keychain``.
    struct BuildKeychain: DeviceIdentityKeychain {
        let keychain: Keychain
        let build: String
        func accountsThrowing() throws -> [String] { keychain.accounts() }
        func read(_ account: String) throws -> Data? { keychain.read(account) }
        func add(_ data: Data, account: String) throws { try keychain.add(data, account: account, build: build) }
        func deleteStatus(_ account: String) -> OSStatus { keychain.delete(account, build: build) }
    }

    /// Software keys stored as their raw bytes (the app stores the Secure Enclave's blobs).
    static let software = DeviceKeyBlobs(
        make: {
            let keys = SoftwareDeviceKeys()
            return (keys, keys.signing.rawRepresentation, keys.agreement.rawRepresentation)
        },
        open: { signing, agreement in
            guard let signing = try? P256.Signing.PrivateKey(rawRepresentation: signing),
                  let agreement = try? P256.KeyAgreement.PrivateKey(rawRepresentation: agreement) else { return nil }
            return StoredSoftwareKeys(signing: signing, agreement: agreement)
        })

    struct StoredSoftwareKeys: DeviceKeyMaterial {
        let signing: P256.Signing.PrivateKey
        let agreement: P256.KeyAgreement.PrivateKey
        var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
        var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
        func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
        func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
            var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                               encapsulatedKey: encapsulatedKey)
            return try recipient.open(ciphertext)
        }
    }

    private func signs(_ identity: DeviceIdentity) throws -> Bool {
        let message = Data("canonical".utf8)
        return DeviceIdentity.verify(signature: try identity.sign(message).base64EncodedString(), of: message,
                                     signingKey: identity.signingKey)
    }

    @Test func aDeviceRenewedOnAnotherBuildGetsANewWorkingIdentityItsLaterLoadsRead() throws {
        let keychain = Keychain()
        let a = BuildKeychain(keychain: keychain, build: "4366880343301")
        let b = BuildKeychain(keychain: keychain, build: "4367130096301")

        let made = try DeviceIdentity.load(keychain: a, keys: Self.software)
        // Installed identities keep their names (generation 1).
        #expect(Set(keychain.accounts()) == ["device-id", "device-signing-key", "device-agreement-key"])
        // Updated in place: build B is the same device.
        let read = try DeviceIdentity.load(keychain: b, keys: Self.software)
        #expect(read.id == made.id && read.signingKey == made.signingKey)

        // The hub refused it on B: B may not delete A's items, and still becomes a new device.
        let renewed = try DeviceIdentity.renew(keychain: b, keys: Self.software)
        #expect(renewed.id != made.id && renewed.signingKey != made.signingKey && renewed.agreementKey != made.agreementKey)
        #expect(try signs(renewed))
        for _ in 0..<2 {
            let later = try DeviceIdentity.load(keychain: b, keys: Self.software)
            #expect(later.id == renewed.id && later.signingKey == renewed.signingKey && later.agreementKey == renewed.agreementKey)
            #expect(try signs(later))
        }
        // A's items stay below; the new identity is one whole generation above them.
        #expect(keychain.accounts().count == 6)
        #expect(keychain.read("device-id.2") == Data(renewed.id.utf8))

        // Renewed again on B: its own generation goes, the new one takes its place.
        let again = try DeviceIdentity.renew(keychain: b, keys: Self.software)
        #expect(again.id != renewed.id)
        #expect(try DeviceIdentity.load(keychain: b, keys: Self.software).id == again.id)
        #expect(keychain.accounts().count == 6)
    }

    @Test func aGenerationMissingAnItemIsNeverMixedWithAnOlderOne() throws {
        let keychain = Keychain()
        let a = BuildKeychain(keychain: keychain, build: "a")
        let b = BuildKeychain(keychain: keychain, build: "b")
        let made = try DeviceIdentity.load(keychain: a, keys: Self.software)
        // A renewal on B that stopped after its first add.
        try keychain.add(Data("half".utf8), account: "device-signing-key.2", build: "b")
        let fresh = try DeviceIdentity.load(keychain: b, keys: Self.software)
        #expect(fresh.id != made.id)
        #expect(try DeviceIdentity.load(keychain: a, keys: Self.software).signingKey == fresh.signingKey)
    }

    @Test func aBuildThatMadeEverythingRenewsInPlace() throws {
        let keychain = Keychain()
        let solo = BuildKeychain(keychain: keychain, build: "solo")
        let made = try DeviceIdentity.load(keychain: solo, keys: Self.software)
        let renewed = try DeviceIdentity.renew(keychain: solo, keys: Self.software)
        #expect(renewed.id != made.id)
        #expect(Set(keychain.accounts()) == ["device-id", "device-signing-key", "device-agreement-key"])
        #expect(try DeviceIdentity.load(keychain: solo, keys: Self.software).id == renewed.id)
    }
}

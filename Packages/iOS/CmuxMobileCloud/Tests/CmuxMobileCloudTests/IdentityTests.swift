import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite struct IdentityTests {
    @Test func keyPairPublicHalfMatchesCryptoKitDerivation() throws {
        let pair = WireGuardKeyPair()
        let raw = try #require(Data(base64Encoded: pair.privateKey))
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == pair.publicKey)
        #expect(raw.count == 32)
    }

    @Test func keyPairRoundTripsThroughStoredPrivateKey() throws {
        let pair = WireGuardKeyPair()
        let restored = try #require(WireGuardKeyPair(privateKey: pair.privateKey))
        #expect(restored == pair)
        #expect(WireGuardKeyPair(privateKey: "not-base64!") == nil)
        #expect(WireGuardKeyPair(privateKey: Data(repeating: 1, count: 16).base64EncodedString()) == nil)
    }

    @Test func mintedFingerprintHasIOSPrefixAndIsUnique() {
        let a = CloudDeviceIdentity.mint()
        let b = CloudDeviceIdentity.mint()
        #expect(a.fingerprint.hasPrefix("ios-"))
        #expect(a.fingerprint != b.fingerprint)
        #expect(a.keyPair != b.keyPair)
    }

    @Test func resolverMintsOnceAndReusesStoredIdentity() async throws {
        let store = InMemoryCloudDeviceIdentityStore()
        let resolver = CloudDeviceIdentityResolver(store: store)
        let first = try await resolver.resolve()
        let second = try await resolver.resolve()
        #expect(first == second)
        #expect(await store.stored == first)
    }

    @Test func resolverFailsClosedWhenStoreIsUnavailable() async {
        let store = InMemoryCloudDeviceIdentityStore(unavailable: true)
        let resolver = CloudDeviceIdentityResolver(store: store)
        await #expect(throws: CloudDeviceIdentityResolver.Failure.storeUnavailable) {
            try await resolver.resolve()
        }
        #expect(await store.stored == nil)
    }
}

@Suite struct UserDefaultsCloudDeviceIdentityStoreTests {
    @Test func roundTripsAndTreatsCorruptDataAsAbsent() throws {
        let suite = "cmux-cloud-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCloudDeviceIdentityStore(defaults: defaults)
        #expect(store.read() == .absent)
        let identity = CloudDeviceIdentity.mint()
        try store.write(identity)
        #expect(store.read() == .found(identity))
        defaults.set(Data("junk".utf8), forKey: "cmux.cloud.deviceIdentity.v1")
        #expect(store.read() == .absent)
    }
}

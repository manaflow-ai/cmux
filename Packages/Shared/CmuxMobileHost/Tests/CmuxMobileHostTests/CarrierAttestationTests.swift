import CmuxLink
import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

/// The carrier's authenticated peer must be the device that signs the hello
/// (b5-mac-host.md 3): B2/B3 name the install, B4's key goes through the
/// trust store.
@Suite("Carrier attestation", .serialized)
struct CarrierAttestationTests {
    static let deviceKey = Data(repeating: 7, count: 32)

    @Test("a carrier that names the hello's install is admitted")
    func matchingInstall() async throws {
        let identity = LinkPeerIdentity(carrier: .webrtc, keyKind: .p256, publicKey: Data(repeating: 1, count: 65),
                                        install: PhoneHarness.install)
        let harness = try await PhoneHarness(carrierIdentity: identity)
        let (_, reply) = try await harness.hello()
        #expect(reply["t"] == "hello.ok")
        await harness.shutdown()
    }

    @Test("a carrier that authenticated another install refuses the hello")
    func otherInstall() async throws {
        let identity = LinkPeerIdentity(carrier: .webrtcWireGuard, keyKind: .x25519, publicKey: Self.deviceKey,
                                        install: "in_other")
        let harness = try await PhoneHarness(carrierIdentity: identity)
        let (_, reply) = try await harness.hello()
        #expect(reply["code"] == "auth.unauthenticated")
        await harness.shutdown()
    }

    @Test("a direct key resolves through the trust store to the hello's install")
    func resolvedKey() async throws {
        let identity = LinkPeerIdentity(carrier: .direct, keyKind: .x25519, publicKey: Self.deviceKey)
        let harness = try await PhoneHarness(carrierIdentity: identity,
                                             keyResolver: FixedKeyResolver(installs: [Self.deviceKey: PhoneHarness.install]))
        let (_, reply) = try await harness.hello()
        #expect(reply["t"] == "hello.ok")
        await harness.shutdown()
    }

    @Test("a direct key no install owns refuses the hello")
    func unresolvedKey() async throws {
        let identity = LinkPeerIdentity(carrier: .direct, keyKind: .x25519, publicKey: Self.deviceKey)
        let harness = try await PhoneHarness(carrierIdentity: identity, keyResolver: FixedKeyResolver(installs: [:]))
        let (_, reply) = try await harness.hello()
        #expect(reply["code"] == "auth.unauthenticated")
        await harness.shutdown()
    }

    @Test("a direct key resolving to another install refuses the hello")
    func keyOfAnotherInstall() async throws {
        let identity = LinkPeerIdentity(carrier: .direct, keyKind: .x25519, publicKey: Self.deviceKey)
        let harness = try await PhoneHarness(carrierIdentity: identity,
                                             keyResolver: FixedKeyResolver(installs: [Self.deviceKey: "in_other"]))
        let (_, reply) = try await harness.hello()
        #expect(reply["code"] == "auth.unauthenticated")
        await harness.shutdown()
    }
}

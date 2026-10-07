import CmuxMobileHost
import CmuxMobileWire
import CryptoKit
import Foundation
import Testing

@Suite("Device admission")
struct TrustStoreAuthorizerTests {
    let key = P256.Signing.PrivateKey()
    let session = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func device(user: String = "u_alice", revoked: Bool = false) -> PairedDevice {
        PairedDevice(install: "in_phone1", userID: user, keyID: "k1", publicKey: key.publicKey.x963Representation, revoked: revoked)
    }

    func authorizer(_ devices: [PairedDevice]) -> TrustStoreAuthorizer {
        let now = now
        return TrustStoreAuthorizer(hostID: "h_mac1", accountUserID: "u_alice", store: StaticTrustStore(devices: devices),
                                    now: { now })
    }

    func request(signer: P256.Signing.PrivateKey? = nil, session: UUID? = nil, issuedAt: Int64? = nil,
                 attestation: CarrierAttestation? = nil, withProof: Bool = true) throws -> DeviceAuthRequest {
        let signer = signer ?? key
        let proof = try DeviceProof(install: "in_phone1", keyID: "k1",
                                    issuedAt: issuedAt ?? Int64(now.timeIntervalSince1970 * 1000),
                                    hostID: "h_mac1", sessionID: session ?? self.session) { try signer.signature(for: $0).rawRepresentation }
        return DeviceAuthRequest(client: HelloClient(install: "in_phone1", platform: "ios", appVersion: "1"),
                                 proof: withProof ? proof : nil, sessionID: self.session, attestation: attestation)
    }

    func code(_ result: Result<MobileDevicePrincipal, MobileAuthFailure>) -> String? {
        if case .failure(let failure) = result { return failure.code }
        return nil
    }

    @Test func admitsAPairedDeviceWithAFreshProof() async throws {
        let result = await authorizer([device()]).authorize(try request())
        #expect(try result.get().install == "in_phone1")
    }

    @Test func refusesWithoutProof() async throws {
        #expect(code(await authorizer([device()]).authorize(try request(withProof: false))) == "auth.unauthenticated")
    }

    @Test func refusesUnpairedRevokedAndOtherAccountDevices() async throws {
        #expect(code(await authorizer([]).authorize(try request())) == "auth.forbidden")
        #expect(code(await authorizer([device(revoked: true)]).authorize(try request())) == "auth.forbidden")
        #expect(code(await authorizer([device(user: "u_mallory")]).authorize(try request())) == "auth.forbidden")
    }

    @Test func refusesAProofForAnotherSessionOrKey() async throws {
        let auth = authorizer([device()])
        #expect(code(await auth.authorize(try request(session: UUID()))) == "auth.unauthenticated")
        #expect(code(await auth.authorize(try request(signer: P256.Signing.PrivateKey()))) == "auth.unauthenticated")
    }

    @Test func refusesStaleAndReplayedProofs() async throws {
        let auth = authorizer([device()])
        let stale = Int64(now.timeIntervalSince1970 * 1000) - 10 * 60 * 1000
        #expect(code(await auth.authorize(try request(issuedAt: stale))) == "auth.unauthenticated")
        let fresh = try request()
        #expect((try? await auth.authorize(fresh).get()) != nil)
        #expect(code(await auth.authorize(fresh)) == "auth.unauthenticated")
    }

    @Test func refusesWhenTheCarrierAuthenticatedAnotherDevice() async throws {
        let attestation = CarrierAttestation(install: "in_other", carrier: "direct")
        #expect(code(await authorizer([device()]).authorize(try request(attestation: attestation))) == "auth.unauthenticated")
    }

    @Test func forwardedOpsNeedAPairedDeviceOfTheAccount() async throws {
        let auth = authorizer([device()])
        #expect((try? await auth.authorizeForwarded(install: "in_phone1", userID: "u_alice").get()) != nil)
        #expect(code(await auth.authorizeForwarded(install: "in_phone1", userID: "u_mallory")) == "auth.forbidden")
        #expect(code(await auth.authorizeForwarded(install: "in_unknown", userID: nil)) == "auth.forbidden")
    }

    @Test func proofRoundTripsThroughHelloJSON() throws {
        let proof = try #require(try request().proof)
        #expect(DeviceProof(json: proof.jsonValue) == proof)
    }
}

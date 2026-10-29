import Foundation
import Testing
import CryptoKit
@testable import CmuxIrxTransport

struct V2WireSigningTests {
    private struct Fixture: Decodable {
        let secretSeedHex: String
        let device: V2DeviceDescriptor
        let challenge: V2Challenge
        let setup: V2SocketSetup
        let issuedAt: Int
        let enrollmentCanonical: String
        let requestCanonical: String
        let enrollmentSignature: String
        let requestSignature: String
        let httpOperation: V2RelayRequest
        let httpCanonical: String
        let httpSignature: String
        let proofNonce: String
    }

    @Test func matchesWorkerCanonicalBytesAndEd25519Signatures() throws {
        let url = try #require(Bundle.module.url(forResource: "signing", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let codec = V2WireSigningCodec()
        let enrollment = try codec.enrollment(device: fixture.device, challenge: fixture.challenge)
        let request = try codec.request(device: fixture.device, requestID: fixture.setup.requestID, issuedAt: fixture.issuedAt, body: fixture.setup, nonce: fixture.proofNonce)
        #expect(String(decoding: enrollment, as: UTF8.self) == fixture.enrollmentCanonical)
        #expect(String(decoding: request, as: UTF8.self) == fixture.requestCanonical)
        let seed = stride(from: 0, to: fixture.secretSeedHex.count, by: 2).map { offset in
            let start = fixture.secretSeedHex.index(fixture.secretSeedHex.startIndex, offsetBy: offset)
            return UInt8(fixture.secretSeedHex[start..<fixture.secretSeedHex.index(start, offsetBy: 2)], radix: 16)!
        }
        let key = try V2IdentityKey(secretKey: Data(seed))
        #expect(key.endpointID == fixture.device.endpointID)
        #expect(enrollment == Data(fixture.enrollmentCanonical.utf8))
        #expect(request == Data(fixture.requestCanonical.utf8))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)).publicKey.rawRepresentation)
        let enrollmentExpected = fixture.enrollmentSignature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        let requestExpected = fixture.requestSignature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        #expect(publicKey.isValidSignature(Data(base64Encoded: enrollmentExpected)!, for: enrollment))
        #expect(publicKey.isValidSignature(Data(base64Encoded: requestExpected)!, for: request))
        #expect(try publicKey.isValidSignature(key.sign(enrollment), for: Data(fixture.enrollmentCanonical.utf8)))
        #expect(try publicKey.isValidSignature(key.sign(request), for: Data(fixture.requestCanonical.utf8)))
        let http = try codec.httpRequest(device: fixture.device, setup: fixture.setup, issuedAt: fixture.issuedAt, request: codec.encode(fixture.httpOperation), nonce: fixture.proofNonce)
        #expect(http == Data(fixture.httpCanonical.utf8))
        let httpExpected = fixture.httpSignature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
        #expect(publicKey.isValidSignature(Data(base64Encoded: httpExpected)!, for: http))
        #expect(try publicKey.isValidSignature(key.sign(http), for: Data(fixture.httpCanonical.utf8)))
    }

    @Test func distinctFreshKeysNeverAdoptOneAnother() {
        let first = V2IdentityKey()
        let second = V2IdentityKey()
        #expect(first.endpointID != second.endpointID)
        #expect(first.secretKey.count == 32)
    }
}

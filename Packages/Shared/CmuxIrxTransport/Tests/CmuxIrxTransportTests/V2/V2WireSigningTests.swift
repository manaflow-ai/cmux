import Foundation
import Testing
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
    }

    @Test func matchesWorkerCanonicalBytesAndEd25519Signatures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/signing.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let codec = V2WireSigningCodec()
        let enrollment = try codec.enrollment(device: fixture.device, challenge: fixture.challenge)
        let request = try codec.request(device: fixture.device, requestID: fixture.setup.requestID, issuedAt: fixture.issuedAt, body: fixture.setup)
        #expect(String(decoding: enrollment, as: UTF8.self) == fixture.enrollmentCanonical)
        #expect(String(decoding: request, as: UTF8.self) == fixture.requestCanonical)
        let seed = stride(from: 0, to: fixture.secretSeedHex.count, by: 2).map { offset in
            let start = fixture.secretSeedHex.index(fixture.secretSeedHex.startIndex, offsetBy: offset)
            return UInt8(fixture.secretSeedHex[start..<fixture.secretSeedHex.index(start, offsetBy: 2)], radix: 16)!
        }
        let key = try V2IdentityKey(secretKey: Data(seed))
        #expect(key.endpointID == fixture.device.endpointID)
        #expect(try codec.base64URL(key.sign(enrollment)) == fixture.enrollmentSignature)
        #expect(try codec.base64URL(key.sign(request)) == fixture.requestSignature)
    }

    @Test func distinctFreshKeysNeverAdoptOneAnother() {
        let first = V2IdentityKey()
        let second = V2IdentityKey()
        #expect(first.endpointID != second.endpointID)
        #expect(first.secretKey.count == 32)
    }
}

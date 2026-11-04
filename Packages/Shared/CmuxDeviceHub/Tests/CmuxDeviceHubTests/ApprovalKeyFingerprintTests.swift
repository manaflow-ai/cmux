@testable import CmuxDeviceHub
import CryptoKit
import Foundation
import Testing

/// Review 2 #1: the iPhone shows its approval key's fingerprint exactly as
/// `cmux computer-use setup --approver` prints it, so a box owner can compare the two.
/// Both sides reproduce schemas/computer-use/approval-key-fingerprint-vector.json
/// (the Rust side with `display_fingerprint(key_fingerprint(..))`).
@Suite struct ApprovalKeyFingerprintTests {
    struct Vector: Decodable {
        var keyBase64: String
        var fingerprintHex: String
        var display: String

        enum CodingKeys: String, CodingKey {
            case keyBase64 = "key_base64", fingerprintHex = "fingerprint_hex", display
        }

        /// The file at the repository root, found from this source file's path.
        static func load(filePath: String = #filePath) throws -> Vector {
            var url = URL(fileURLWithPath: filePath)
            // Tests/CmuxDeviceHubTests/<file> → Packages/Shared/CmuxDeviceHub → repository root.
            for _ in 0 ..< 6 { url.deleteLastPathComponent() }
            let data = try Data(contentsOf: url.appendingPathComponent("schemas/computer-use/approval-key-fingerprint-vector.json"))
            return try JSONDecoder().decode(Vector.self, from: data)
        }
    }

    /// The vector's private key: the P-256 scalar SHA-256("cmux computer use approval key fingerprint vector").
    static func vectorKey() throws -> ComputerUseApprovalKey {
        let scalar = Data(SHA256.hash(data: Data("cmux computer use approval key fingerprint vector".utf8)))
        let key = try P256.Signing.PrivateKey(rawRepresentation: scalar)
        return ComputerUseApprovalKey(material: SoftwareApprovalKey(key: key), factory: .software)
    }

    @Test func theVectorIsAP256KeyAndItsFingerprintsMatch() throws {
        let vector = try Vector.load()
        let bytes = try #require(Data(base64Encoded: vector.keyBase64))
        #expect(bytes.count == 65 && bytes.first == 0x04)
        _ = try P256.Signing.PublicKey(x963Representation: bytes)
        #expect(DeviceIdentity.fingerprint(signingKey: vector.keyBase64) == vector.fingerprintHex)
        #expect(DeviceIdentity.displayFingerprint(vector.fingerprintHex) == vector.display)
        #expect(ComputerUseApprovalKey.displayFingerprint(publicKey: vector.keyBase64) == vector.display)
        #expect(ComputerUseApprovalKey.displayFingerprint(publicKey: "not a key") == nil)
    }

    @Test func whatTheIPhoneShowsIsTheApprovalKeysSetupFingerprint() throws {
        let vector = try Vector.load()
        let key = try Self.vectorKey()
        #expect(key.publicKey == vector.keyBase64)
        #expect(key.fingerprint == vector.fingerprintHex)
        #expect(key.displayFingerprint == vector.display)
        // What Settings → Computer Use shows: the identity's approval key, and nothing without one.
        #expect(DeviceIdentity.software(approvalKey: key).approvalKeyDisplayFingerprint == vector.display)
        #expect(DeviceIdentity.software().approvalKeyDisplayFingerprint == nil)
        // Never the device's signing key.
        let identity = DeviceIdentity.software(approvalKey: key)
        #expect(identity.approvalKeyDisplayFingerprint != DeviceIdentity.displayFingerprint(identity.fingerprint))
    }
}

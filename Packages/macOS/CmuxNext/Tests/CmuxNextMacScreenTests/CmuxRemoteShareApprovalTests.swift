import CmuxNextDevices
import CryptoKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The approval this device signs after the Allow click reads, byte for byte, as the Rust side
/// that verifies it on the target Mac (`acpmux/src/share_approval.rs`): both read
/// `share_approval_vectors.json`.
@Suite struct CmuxRemoteShareApprovalTests {
    static func vectors() -> [[String: Any]] {
        let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let file = repo.appendingPathComponent("cmux-tui/crates/acpmux/src/share_approval_vectors.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    static func approval(_ fields: [String: Any]) -> CmuxRemoteShareApproval {
        let text: (String) -> String = { fields[$0] as? String ?? "" }
        return CmuxRemoteShareApproval(target: text("target"), targetName: text("target_name"), asker: text("asker"),
                                       askerName: text("asker_name"), confirmedBy: text("confirmed_by"),
                                       confirmedAt: Int(text("confirmed_at")) ?? -1, nonce: text("nonce"))
    }

    @Test func canonicalMatchesTheRustVectors() {
        let vectors = Self.vectors()
        #expect(!vectors.isEmpty)
        for vector in vectors {
            let fields = vector["approval"] as? [String: Any] ?? [:]
            #expect(fields["v"] as? String == CmuxRemoteShareApproval.version)
            #expect(Self.approval(fields).canonical == vector["canonical"] as? String)
        }
    }

    @Test func theAnswerCarriesEveryFieldTheTargetReads() {
        let fields = Self.vectors().first?["approval"] as? [String: Any] ?? [:]
        let json = Self.approval(fields).json
        for key in ["v", "target", "target_name", "asker", "asker_name", "confirmed_by", "confirmed_at", "nonce", "signature"] {
            #expect(json[key]?.stringValue == fields[key] as? String, "\(key)")
        }
    }

    @Test func theSignatureVerifiesWithTheDevicesHubKey() throws {
        let identity = DeviceIdentity(deviceID: UUID(), keys: ShareTestKeys())
        let fields = Self.vectors().first?["approval"] as? [String: Any] ?? [:]
        let signed = try Self.approval(fields).signed(by: identity)
        #expect(DeviceIdentity.verify(signature: signed.signature, of: Data(signed.canonical.utf8), signingKey: identity.signingKey))
        var changed = signed
        changed.target = "another-mac"
        #expect(!DeviceIdentity.verify(signature: changed.signature, of: Data(changed.canonical.utf8), signingKey: identity.signingKey))
    }

    /// The dialog waits as long as `cmux remote-host`'s `CONFIRM_TIMEOUT` (600 s), not the old 130 s.
    @Test func theConfirmDialogWaitsForThePersonPastTheOldTimeout() {
        #expect(CmuxRemoteActionEnvironment.confirmationTimeout == .seconds(600))
        #expect(CmuxRemoteActionEnvironment.confirmationTimeout > .seconds(130))
    }
}

/// A software signing key: tests only. The app signs with its Secure Enclave key.
nonisolated private struct ShareTestKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()

    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }

    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }

    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data { Data() }
}

import CmuxNextDevices
import CmuxNextSettings
import Foundation

/// What this device signs after the person clicks Allow on "Share Studio's screen with your
/// devices?": the Mac to share, this device, the account, when, and a nonce. The Rust side
/// (`cmux-tui/crates/acpmux/src/share_approval.rs`) verifies it on the target Mac;
/// `share_approval_vectors.json` holds both sides to one canonical string.
nonisolated struct CmuxRemoteShareApproval: Equatable, Sendable {
    static let version = "cmux.share-approval.v1"

    var target: String
    var targetName: String
    var asker: String
    var askerName: String
    var confirmedBy: String
    var confirmedAt: Int
    var nonce: String
    var signature = ""

    /// The signed bytes, one field per line (`ShareApproval::canonical` in Rust).
    var canonical: String {
        "\(Self.version)\ntarget=\(target)\nasker=\(asker)\nconfirmed_by=\(confirmedBy)\nconfirmed_at=\(confirmedAt)\nnonce=\(nonce)"
    }

    /// Signs it with this device's key. Called only after the person's Allow click.
    func signed(by identity: DeviceIdentity) throws -> CmuxRemoteShareApproval {
        var copy = self
        copy.signature = try identity.sign(canonical: canonical)
        return copy
    }

    /// The `approval` object of `remote.confirm`'s answer.
    var json: CmuxNextSettings.JSONValue {
        .object([
            "v": .string(Self.version),
            "target": .string(target),
            "target_name": .string(targetName),
            "asker": .string(asker),
            "asker_name": .string(askerName),
            "confirmed_by": .string(confirmedBy),
            "confirmed_at": .string(String(confirmedAt)),
            "nonce": .string(nonce),
            "signature": .string(signature),
        ])
    }
}

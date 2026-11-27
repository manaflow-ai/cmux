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

    /// The signed bytes, one field per line (`ShareApproval::canonical` in Rust, op `agents.approval`).
    var canonical: String { rd?["canonical"] as? String ?? "" }

    /// Signs it with this device's key. Called only after the person's Allow click.
    func signed(by identity: DeviceIdentity) throws -> CmuxRemoteShareApproval {
        var copy = self
        copy.signature = try identity.sign(canonical: canonical)
        return copy
    }

    /// The `approval` object of `remote.confirm`'s answer (`ShareApproval::wire`).
    var json: CmuxNextSettings.JSONValue { RdUI.decode(rd?["wire"]) ?? .null }

    private var rd: [String: Any]? {
        RdUI.call("agents.approval", ["target": target, "targetName": targetName, "asker": asker, "askerName": askerName,
                                      "confirmedBy": confirmedBy, "confirmedAt": confirmedAt, "nonce": nonce,
                                      "signature": signature]) as? [String: Any]
    }
}

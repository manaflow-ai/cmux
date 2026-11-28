import Foundation

/// One profile (Touch ID) passkey: metadata only, never key material.
public nonisolated struct ChromiumPasskey: Sendable, Hashable {
    /// The credential id, base64url without padding (the delete key).
    public var credentialID: String
    public var relyingParty: String
    public var userName: String
    public var userDisplayName: String

    public init(credentialID: String, relyingParty: String, userName: String, userDisplayName: String) {
        self.credentialID = credentialID
        self.relyingParty = relyingParty
        self.userName = userName
        self.userDisplayName = userDisplayName
    }

    /// The fork's list JSON (`[{"rp_id","credential_id","user_name","user_display_name"}]`);
    /// nil when it is not a JSON array. Rows without a credential id are dropped.
    static func parse(_ json: String) -> [ChromiumPasskey]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["credential_id"] as? String, !id.isEmpty else { return nil }
            return ChromiumPasskey(credentialID: id, relyingParty: row["rp_id"] as? String ?? "",
                                   userName: row["user_name"] as? String ?? "",
                                   userDisplayName: row["user_display_name"] as? String ?? "")
        }
    }
}

/// Why a passkey call failed.
public nonisolated enum ChromiumPasskeyError: Error, Sendable, Equatable {
    /// The running fork has no passkey calls (API below 18), or Chromium is not running.
    case unavailable
    /// The macOS keychain could not be read.
    case keychainUnreadable
}

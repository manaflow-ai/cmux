import Foundation

/// Metadata for one profile passkey. Key material never crosses the CEF shim.
public nonisolated struct ChromiumPasskey: Sendable, Hashable {
    /// Base64url credential id without padding; this is the delete key.
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

    /// Parses the fork's metadata-only passkey array.
    public static func parse(_ json: String) -> [ChromiumPasskey]? {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { row in
            guard let credentialID = row["credential_id"] as? String, !credentialID.isEmpty else { return nil }
            return ChromiumPasskey(
                credentialID: credentialID,
                relyingParty: row["rp_id"] as? String ?? "",
                userName: row["user_name"] as? String ?? "",
                userDisplayName: row["user_display_name"] as? String ?? ""
            )
        }
    }
}

/// Why a profile passkey or password operation could not run.
public nonisolated enum ChromiumPasswordError: Error, Sendable, Equatable {
    /// The bundled fork is too old or the Chromium runtime is unavailable.
    case unavailable
    /// The profile keychain/store could not be read.
    case storeUnreadable
    /// A profile operation was requested for an off-the-record profile.
    case offTheRecord
}

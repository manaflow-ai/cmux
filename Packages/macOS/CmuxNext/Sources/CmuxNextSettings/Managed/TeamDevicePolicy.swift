import CryptoKit
public import Foundation

extension TeamPolicyLayer {
    /// The layer for the backend read `team.device.policy` (decision E3: only
    /// the device's managing team). nil when that team does not manage this
    /// install, so the caller clears the layer with `.none`. Keys are already
    /// cmux.json key paths; keys this build does not know have no effect.
    public init?(devicePolicy value: JSONValue) {
        guard value["managed"]?.boolValue == true else { return nil }
        self.init(
            teamName: value["team_name"]?.stringValue ?? "",
            defaults: value["defaults"]?.objectValue ?? [:],
            enforced: value["enforced"]?.objectValue ?? [:],
            teamID: value["team"]?.stringValue ?? "",
            version: value["version"]?.intValue ?? 0
        )
        self = limitedToCatalog()
    }
}

extension ManagedPreferences {
    /// What `team.device.enroll` takes for the MDM `EnrollmentToken`:
    /// base64url(SHA-256(token)) without padding. The raw token never leaves
    /// the device. The backend test uses the same vector.
    public static func enrollmentTokenHash(_ token: String) -> String {
        Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The forced `EnrollmentToken`, trimmed; nil when absent or empty. A
    /// non-forced value is ignored: any local user could have written it.
    public var enrollmentToken: String? {
        let token = forced["EnrollmentToken"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

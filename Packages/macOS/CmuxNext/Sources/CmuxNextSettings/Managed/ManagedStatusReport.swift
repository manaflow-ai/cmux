public import Foundation

/// What a device's MDM tooling can read about cmux's managed settings
/// (plans/cmux-next/enterprise.md "Status paths"): osquery, Fleet, Jamf
/// extension attributes and `cmux mdm status --json` read the status file
/// the config layer writes after each applied load. Names and sources only
/// for secrets: the value of `EnrollmentToken` never appears.
public nonisolated enum ManagedStatusReport {
    public static let schemaVersion = 1
    /// Keys whose values the report never includes.
    static let secretKeys: Set<String> = ["EnrollmentToken"]

    /// Who runs: set by the App (tests pass a fixed one).
    public struct Context: Sendable, Equatable {
        public var appVersion: String
        public var bundleID: String

        public init(appVersion: String, bundleID: String) {
            self.appVersion = appVersion
            self.bundleID = bundleID
        }
    }

    /// The report without its timestamp, so a load that changes nothing writes nothing.
    public static func body(context: Context, managed: ManagedPreferences, team: TeamPolicyLayer, effective: EffectiveSettings) -> JSONValue {
        let applied = effective.managedKeys.sorted { $0.key < $1.key }.map { key, layer -> JSONValue in
            let source: String
            switch layer {
            case .device: source = "mdm"
            case .team: source = "team"
            }
            return .object(["key": .string(key), "source": .string(source), "value": effective.root.value(at: EffectiveSettings.path(key)) ?? .null])
        }
        return .object([
            "schema_version": JSONValue(schemaVersion),
            "app": .object(["version": .string(context.appVersion), "bundle_id": .string(context.bundleID)]),
            "domain": .string(ManagedPreferences.domain),
            "profile_present": .bool(!managed.forced.isEmpty || !managed.recommended.isEmpty),
            "keys_forced": .array(managed.forced.keys.sorted().map(JSONValue.string)),
            "keys_recommended": .array(managed.recommended.keys.sorted().map(JSONValue.string)),
            "applied": .array(applied),
            "conflicts": .array(conflicts(managed: managed, team: team)),
            "policy": .object(managed.policyKeysForReport),
            "enrollment_token_present": .bool(managed.enrollmentToken != nil),
            "managing_team": team.teamID.isEmpty ? .null : .object([
                "id": .string(team.teamID), "name": .string(team.teamName), "policy_version": JSONValue(team.version),
            ]),
        ])
    }

    /// Decision E2: the MDM value wins and the conflict is reported.
    public static func conflicts(managed: ManagedPreferences, team: TeamPolicyLayer) -> [JSONValue] {
        team.enforced.keys.sorted().filter { !ChatSettings.keys.contains($0) }.compactMap { key in
            guard let device = managed.forced[key], let teamValue = team.enforced[key], device != teamValue else { return nil }
            return .object(["key": .string(key), "mdm_value": device, "team_value": teamValue, "winner": "mdm"])
        }
    }

    /// The file document: the body plus when it was written.
    public static func document(body: JSONValue, writtenAt: Date) -> JSONValue {
        guard case .object(var members) = body else { return body }
        members["written_at"] = .string(writtenAt.formatted(.iso8601))
        return .object(members)
    }

    /// Where the App writes the file: one stable path for the release app,
    /// a per-bundle file for NIGHTLY, RC and DEV builds.
    public static func defaultURL(bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let directory = home.appending(path: "Library/Application Support/cmux", directoryHint: .isDirectory)
        return directory.appending(path: bundleID == "com.cmuxterm.app" ? "managed-status.json" : "managed-status.\(bundleID).json")
    }
}

extension ManagedPreferences {
    /// Forced policy keys (capitalized) with values, except secrets, which show as present.
    var policyKeysForReport: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in forced where !ManagedPreferences.isSettingKey(key) {
            result[key] = ManagedStatusReport.secretKeys.contains(key) ? .string("<set>") : value
        }
        return result
    }
}

public import Foundation

/// Device-scoped values from the policy of the device's managing team
/// (spec/enterprise.md 4.4, decision E3). Keys are cmux.json key paths.
/// The App fills this from TeamDO's `team.policy.get`; empty until then.
public nonisolated struct TeamPolicyLayer: Sendable, Equatable {
    public var teamName: String
    public var defaults: [String: JSONValue]
    public var enforced: [String: JSONValue]

    public init(teamName: String = "", defaults: [String: JSONValue] = [:], enforced: [String: JSONValue] = [:]) {
        self.teamName = teamName
        self.defaults = defaults
        self.enforced = enforced
    }

    public static let none = TeamPolicyLayer()
}

/// The effective settings document and what manages it.
public nonisolated struct EffectiveSettings: Sendable, Equatable {
    /// What every module reads (the parsers run over this).
    public var root: JSONValue
    /// The user's own file, for "is this customized" and writes.
    public var fileRoot: JSONValue
    /// Dotted key -> manager, for keys a forced layer sets.
    public var managedKeys: [String: ManagedSource]
    /// Managed policy keys that are not settings (`EnrollmentToken`, ...), forced and recommended merged, forced first.
    public var policy: [String: JSONValue]
    /// The user's file sets a key a policy overrides.
    public var diagnostics: [SettingsDiagnostic]

    /// Merges, highest first: MDM forced, team enforced, the user's file,
    /// MDM recommended, team default, product default (an absent key).
    /// Lawrence's rule "MDM-managed device setting > team policy > user
    /// setting" is the first three; the rest keeps unmanaged keys customizable.
    public static func merge(file: JSONValue, managed: ManagedPreferences, team: TeamPolicyLayer) -> EffectiveSettings {
        var root = file.objectValue == nil ? JSONValue.object([:]) : file
        var managedKeys: [String: ManagedSource] = [:]
        var policy: [String: JSONValue] = [:]
        var diagnostics: [SettingsDiagnostic] = []

        // Below the file: fill only absent keys; MDM recommended outranks team default.
        for (key, value) in sortedSettingEntries(managed.recommended) where root.value(at: path(key)) == nil {
            root = root.setting(value, at: path(key))
        }
        for (key, value) in sortedSettingEntries(team.defaults) where root.value(at: path(key)) == nil {
            root = root.setting(value, at: path(key))
        }
        // Above the file: team enforced, then MDM forced overwrites.
        for (key, value) in sortedSettingEntries(team.enforced) {
            root = root.setting(value, at: path(key))
            managedKeys[key] = .team(team.teamName)
        }
        for (key, value) in sortedSettingEntries(managed.forced) {
            root = root.setting(value, at: path(key))
            managedKeys[key] = .device
        }
        for key in managedKeys.keys.sorted() {
            if let mine = file.value(at: path(key)), mine != root.value(at: path(key)) {
                diagnostics.append(SettingsDiagnostic(kind: .managedOverride, path: key, message: "managed by your organization; the value in cmux.json is ignored"))
            }
        }
        for (key, value) in managed.recommended where !ManagedPreferences.isSettingKey(key) { policy[key] = value }
        for (key, value) in managed.forced where !ManagedPreferences.isSettingKey(key) { policy[key] = value }
        return EffectiveSettings(root: root, fileRoot: file, managedKeys: managedKeys, policy: policy, diagnostics: diagnostics)
    }

    static func path(_ key: String) -> [String] { CmuxConfigFile.keyPath(from: key) }

    /// Deterministic order, settings keys only (a shorter key first, so a
    /// nested key set later wins over an object set at its parent).
    static func sortedSettingEntries(_ values: [String: JSONValue]) -> [(String, JSONValue)] {
        values.filter { ManagedPreferences.isSettingKey($0.key) }
            .sorted { ($0.key.count, $0.key) < ($1.key.count, $1.key) }
    }
}

extension JSONValue {
    /// A copy with `value` at `path`, creating objects along the way (a
    /// non-object in the way is replaced).
    func setting(_ value: JSONValue, at path: [String]) -> JSONValue {
        guard let head = path.first else { return value }
        var members = objectValue ?? [:]
        members[head] = (members[head] ?? .object([:])).setting(value, at: Array(path.dropFirst()))
        return .object(members)
    }
}

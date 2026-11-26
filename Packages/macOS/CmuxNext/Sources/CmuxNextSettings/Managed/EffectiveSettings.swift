public import Foundation

/// Device-scoped values from the policy of the device's managing team
/// (spec/enterprise.md 4.4, decision E3). Keys are cmux.json key paths.
/// The App fills this from TeamDO's `team.policy.get`; empty until then.
public nonisolated struct TeamPolicyLayer: Sendable, Equatable {
    public var teamName: String
    public var defaults: [String: JSONValue]
    public var enforced: [String: JSONValue]
    /// The managing team's id and the policy version these values come from (status reports).
    public var teamID: String
    public var version: Int

    public init(teamName: String = "", defaults: [String: JSONValue] = [:], enforced: [String: JSONValue] = [:], teamID: String = "", version: Int = 0) {
        self.teamName = teamName
        self.defaults = defaults
        self.enforced = enforced
        self.teamID = teamID
        self.version = version
    }

    public static let none = TeamPolicyLayer()

    /// Only keys the settings catalog lists, and their older names (``EffectiveSettings/legacyKeys``).
    public func limitedToCatalog() -> TeamPolicyLayer {
        // An empty layer (every launch's `.none`) filters to itself: without this, `main` built the whole
        // schema with its localized texts (`SettingsSchema.all`) on the main thread through
        // `FontSmoothingSetting.applyBeforeLaunch`, 41 ms before the Dock stopped bouncing (CMUX-631).
        guard !defaults.isEmpty || !enforced.isEmpty else { return self }
        let ids = Set(SettingsSchema.all.map(\.id)).union(EffectiveSettings.legacyKeys.keys)
            .union(EffectiveSettings.replacedOldKeys)
        var copy = self
        copy.defaults = defaults.filter { ids.contains($0.key) }
        copy.enforced = enforced.filter { ids.contains($0.key) }
        return copy
    }
}

/// The effective settings document and what manages it.
public nonisolated struct EffectiveSettings: Sendable, Equatable {
    /// What every module reads (the parsers run over this).
    public var root: JSONValue
    /// The user's own file, for "is this customized" and writes.
    public var fileRoot: JSONValue
    /// Dotted key -> manager, for keys a forced layer sets.
    public var managedKeys: [String: ManagedSource]
    /// Managed policy keys that are not settings (`EnrollmentToken`, ...), from forced values only.
    public var policy: [String: JSONValue]
    /// The user's file sets a key a policy overrides.
    public var diagnostics: [SettingsDiagnostic]
    /// Additive administrator roots, including refused paths for locked-row diagnostics.
    public var managedChatRoots: [String] = []

    /// Merges, highest first: MDM forced, team enforced, the user's file,
    /// MDM recommended, team default, product default (an absent key).
    /// Lawrence's rule "MDM-managed device setting > team policy > user
    /// setting" is the first three; the rest keeps unmanaged keys customizable.
    /// Chats are merged by their own rules: roots add up and switches can only be forced off.
    /// Rust merges (cmux-config app_ops/effective.rs, `effective.merge`); the team layer may only
    /// set catalog settings (never a whole object, shortcuts or custom actions).
    public static func merge(file: JSONValue, managed: ManagedPreferences, team: TeamPolicyLayer) -> EffectiveSettings {
        let team = team.limitedToCatalog()
        let reply = SettingsRust.answer("effective.merge", [
            "file": file,
            "managed": ["forced": .object(managed.forced), "recommended": .object(managed.recommended)],
            "team": ["teamName": .string(team.teamName), "defaults": .object(team.defaults), "enforced": .object(team.enforced)],
            "legacyKeys": .object(legacyKeys.mapValues(JSONValue.string)),
            "chats": ["roots": .string(ChatSettings.rootsPath.joined(separator: ".")), "booleans": .array(ChatSettings.booleanKeys.map(JSONValue.string))],
        ])
        let managedKeys = (reply["managedKeys"]?.objectValue ?? [:]).mapValues { source in
            source["team"]?.stringValue.map(ManagedSource.team) ?? .device
        }
        let diagnostics = (reply["diagnostics"]?.arrayValue ?? []).compactMap { item -> SettingsDiagnostic? in
            guard let kind = item["kind"]?.stringValue.flatMap(SettingsDiagnostic.Kind.init(rawValue:)),
                  let path = item["path"]?.stringValue, let message = item["message"]?.stringValue else { return nil }
            return SettingsDiagnostic(kind: kind, path: path, message: message)
        }
        return EffectiveSettings(root: reply["root"] ?? .object([:]), fileRoot: file, managedKeys: managedKeys,
                                 policy: reply["policy"]?.objectValue ?? [:], diagnostics: diagnostics,
                                 managedChatRoots: (reply["managedChatRoots"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    static func path(_ key: String) -> [String] { CmuxConfigFile.keyPath(from: key) }

    /// Older names of settings keys, still read when the new key is absent in the same layer:
    /// the layer's value moves to the new key, so a forced older key locks the new one too.
    static let legacyKeys = [
        LinkRouting.legacyOpenPath.joined(separator: "."): LinkRouting.openPath.joined(separator: "."),
        AgentPaneDisplaySettingsSchema.legacySessionInfoPlacementPath.joined(separator: "."):
            AgentPaneDisplaySettingsSchema.sessionInfoPlacementPath.joined(separator: "."),
    ]

    /// The dotted names of the retired keys a row replaced (retired-keys.json `replaced_by`), read from
    /// managed profiles and team policies too, so an older profile keeps its value and its lock.
    public static var replacedOldKeys: [String] {
        SettingsSchema.replacedKeys.values.flatMap { $0.map { $0.old.joined(separator: ".") } }.sorted()
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

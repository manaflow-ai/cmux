/// Private per-repository script overrides and prompt preferences.
public struct RepositoryScriptPreference: Identifiable, Sendable, Equatable, SettingCodable {
    /// Stable identity used by Settings collections.
    public var id: String { repositoryID }

    /// SHA-256 identity derived from Git's canonical shared common directory.
    public var repositoryID: String

    /// Most recently observed work-tree root, retained for a human-readable config file.
    public var repositoryRoot: String

    /// User-authored setup script, or `nil` when no setup override is configured.
    public var setup: String?

    /// User-authored archive script, or `nil` when no archive override is configured.
    public var archive: String?

    /// Whether the private scripts replace scripts from the project config.
    public var overridesProjectScripts: Bool

    /// Whether the no-setup prompt was dismissed for this repository.
    public var promptDismissed: Bool

    /// Creates a repository script preference.
    ///
    /// - Parameters:
    ///   - repositoryID: Stable identity derived from Git's common directory.
    ///   - repositoryRoot: Most recently observed work-tree root.
    ///   - setup: Private setup-script override.
    ///   - archive: Private archive-script override.
    ///   - overridesProjectScripts: Whether private values replace project values.
    ///   - promptDismissed: Whether the no-setup prompt is dismissed.
    public init(
        repositoryID: String,
        repositoryRoot: String,
        setup: String? = nil,
        archive: String? = nil,
        overridesProjectScripts: Bool = false,
        promptDismissed: Bool = false
    ) {
        self.repositoryID = repositoryID
        self.repositoryRoot = repositoryRoot
        self.setup = setup
        self.archive = archive
        self.overridesProjectScripts = overridesProjectScripts
        self.promptDismissed = promptDismissed
    }

    /// Decodes a preference from its property-list representation.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? { decode(raw) }

    /// Encodes the preference as a property-list dictionary.
    public func encodeForUserDefaults() -> Any { encode() }

    /// Decodes a preference from its JSON object representation.
    public static func decodeFromJSON(_ raw: Any?) -> Self? { decode(raw) }

    /// Encodes the preference as a JSON object dictionary.
    public func encodeForJSON() -> Any { encode() }

    private static func decode(_ raw: Any?) -> Self? {
        guard let value = raw as? [String: Any],
              let repositoryID = value["repositoryID"] as? String,
              let repositoryRoot = value["repositoryRoot"] as? String else { return nil }
        return Self(
            repositoryID: repositoryID,
            repositoryRoot: repositoryRoot,
            setup: value["setup"] as? String,
            archive: value["archive"] as? String,
            overridesProjectScripts: value["overridesProjectScripts"] as? Bool ?? false,
            promptDismissed: value["promptDismissed"] as? Bool ?? false
        )
    }

    private func encode() -> Any {
        var value: [String: Any] = [
            "repositoryID": repositoryID,
            "repositoryRoot": repositoryRoot,
            "overridesProjectScripts": overridesProjectScripts,
            "promptDismissed": promptDismissed,
        ]
        if let setup { value["setup"] = setup }
        if let archive { value["archive"] = archive }
        return value
    }
}

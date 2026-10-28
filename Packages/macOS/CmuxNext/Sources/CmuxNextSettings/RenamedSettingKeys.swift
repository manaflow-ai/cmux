import CmuxNextAppearance

/// Keys a newer key replaced while the app still applies the old one when the new key is absent.
/// Settings reads the old key's value for the new row (``SettingDescriptor/storedValue(in:)``), and
/// every write or reset of the new row removes the old key, so it never applies again behind it.
nonisolated enum RenamedSettingKeys {
    /// The old key `path` replaced, if any.
    static func legacyPath(for path: [String]) -> [String]? {
        // `appearance.background` replaced the paintings-only `appearance.backdropArt`
        // (BackdropSelectionSetting reads it when `appearance.background` is absent).
        if path == BackdropSelectionSetting().configPath { return BackdropArtSetting().configPath }
        return WorkspaceRowSetting.legacyPath(for: path)
    }

    /// The old key's value as the new row shows it: what the app applies from it.
    static func legacyValue(for path: [String], in root: JSONValue) -> JSONValue? {
        guard let legacy = legacyPath(for: path), let value = root.value(at: legacy) else { return nil }
        guard legacy == BackdropArtSetting().configPath else { return value }
        // As BackdropArtSetting parses it: a bundled work (a retired id names its stand-in), else
        // nothing is painted, which the background row calls none.
        return .string(value.stringValue.flatMap(BackdropArt.init(id:))?.rawValue ?? "none")
    }
}

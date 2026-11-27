/// Keys a newer key replaced while the app still applies the old one when the new key is absent.
/// Settings reads the old key's value for the new row (``SettingDescriptor/storedValue(in:)``), and
/// every write or reset of the new row removes the old key, so it never applies again behind it.
nonisolated enum RenamedSettingKeys {
    /// The old keys `path` replaced, in the order they are read; empty when none.
    static func legacyPaths(for path: [String]) -> [[String]] {
        // Retired keys with `replaced_by` (schemas/settings/retired-keys.json), e.g. the
        // `remote.ultraMode` toggle `remote.ultra` replaced, or the three update toggles
        // `updates.automatic` replaced.
        if let replaced = SettingsSchema.replacedKeys[path] { return replaced.map(\.old) }
        return legacyPath(for: path).map { [$0] } ?? []
    }

    /// The one old key a hand-written rename replaced, if any.
    private static func legacyPath(for path: [String]) -> [String]? {
        // `appearance.background` replaced the paintings-only `appearance.backdropArt`
        // (BackdropSelectionSetting reads it when `appearance.background` is absent).
        if path == BackdropSelectionSetting.configPath { return BackdropArtSetting.configPath }
        // `agentPane.display.sessionInfo.placement` replaced `agentPane.display.inspector.placement`, the
        // panel's old name (Leo, 2026-11-01: "WHY THE F***ING HAS IT STILL BEEN CALLED INSPECTOR").
        if path == AgentPaneDisplaySettingsSchema.sessionInfoPlacementPath { return AgentPaneDisplaySettingsSchema.legacySessionInfoPlacementPath }
        // `computerUse.mode` replaced the on/off switch `computerUse.enabled` (cmux Computer Use,
        // 2026-11-05): an old `"enabled": false` reads as mode "off" until the person picks a mode.
        if path == ComputerUseSettings.modePath { return ComputerUseSettings.enabledPath }
        return WorkspaceRowSetting.legacyPath(for: path)
    }

    /// The old key's value as the new row shows it: what the app applies from it (cmux-config
    /// `migrate.legacy_value`: the retired-keys table, `computerUse.enabled` and `appearance.backdropArt`).
    static func legacyValue(for path: [String], in root: JSONValue) -> JSONValue? {
        SettingsRust.answer("migrate.legacy_value", ["path": .array(path.map(JSONValue.string)), "root": root])["value"]
    }
}

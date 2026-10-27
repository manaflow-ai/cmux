import CmuxNextDesignTokens

/// Settings > Window Background: Material "Ghostty" (both keys unset) takes
/// opacity and blur from the Ghostty config. Moving Opacity leaves Ghostty for
/// the material its blur gives; resetting Opacity returns that material to
/// Ghostty (a material the user chose stays), and resetting Material resets both.
/// Every writer (the page, the palette, the socket's `settings.set`) and the
/// page's live preview share this rule (`WindowBackgroundSetting.linkedEdits`).
extension SettingsController {
    /// The material the config files' own `background-blur` gives (`ghosttyBackgroundBlur`).
    var ghosttyWindowMaterial: WindowMaterialChoice {
        WindowMaterialChoice(ghosttyBlur: ghosttyBackgroundBlur?() ?? 0)
    }

    /// The linked window background edits for writing `value` at `path`, read against `root`;
    /// a managed key is never written.
    func windowBackgroundLinkedEdits(writing path: [String], value: JSONValue?,
                                     in root: JSONValue) -> [(path: [String], value: JSONValue?)] {
        WindowBackgroundSetting.linkedEdits(writing: path, value: value, in: root, ghosttyMaterial: ghosttyWindowMaterial)
            .filter { managedKeys[$0.path.joined(separator: ".")] == nil }
    }

    /// The linked edits for a write, read against the file as it is now.
    func windowBackgroundLinkedEdits(writing path: [String], value: JSONValue?) async throws -> [(path: [String], value: JSONValue?)] {
        let keys = [WindowBackgroundSetting.opacityPath, WindowBackgroundSetting.materialPath]
        guard keys.contains(path) else { return [] }
        var root = JSONValue.object([:])
        for key in keys {
            if let stored = try await file.value(at: key) { root = Self.replacing(key, with: stored, in: root) }
        }
        return windowBackgroundLinkedEdits(writing: path, value: value, in: root)
    }
}

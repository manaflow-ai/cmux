import CmuxNextDesign
import Foundation

/// Live preview (R93): the palette shows a value before it is written.
/// A preview is client view state (plans/cmux-next/settings-react.md 1): it
/// applies a snapshot with the value in place and never writes
/// cmux-next.json. Leaving restores the loaded snapshot; committing writes
/// the value and the reload keeps the same look.
extension SettingsController {
    /// Shows `value` for `descriptor` (nil previews the default). Refuses a
    /// managed key or a value the schema refuses, returning false.
    @discardableResult
    public func preview(_ descriptor: SettingDescriptor, _ value: JSONValue?) -> Bool {
        preview([(descriptor, value)])
    }

    /// Shows several values at once as one preview (the whole-app theme preview: the terminal theme
    /// with the App Theme following it). Refuses all of them, showing nothing, when any key is
    /// managed or any value refused. `previewingKey` is the first key's.
    @discardableResult
    public func preview(_ edits: [(SettingDescriptor, JSONValue?)]) -> Bool {
        guard let first = edits.first else { return false }
        for (descriptor, value) in edits {
            guard managedKeys[descriptor.id] == nil else { return false }
            if let value, !descriptor.accepts(value) { return false }
        }
        func edit(_ root: JSONValue) -> JSONValue {
            edits.reduce(root) { current, edit in
                let (descriptor, value) = edit
                // Each linked edit sees the preceding preview edits, just as a saved batch does.
                let linked = windowBackgroundLinkedEdits(writing: descriptor.path, value: value, in: current)
                let written = Self.replacing(descriptor.path, with: value, in: current)
                return linked.reduce(written) { Self.replacing($1.path, with: $1.value, in: $0) }
            }
        }
        // From the settings under the theme file, so a previewed theme file replaces the active one.
        var root = edit(themeFile == nil ? snapshot.root : rootUnderThemeFile)
        var themeDensity: DensityTokens?
        if let name = ThemeFileSetting.name(in: root) {
            // The theme file applies (the last load's read: no disk read here), then the previewed
            // values over it, so a previewed key shows even where the file sets it.
            let overlay = name == themeFile?.name ? themeFile
                : ThemeFileOverlay(name: name, source: themeFileSources[name].map { .success($0) }, base: root,
                                   folder: ThemeFileSetting.folder(configDirectory: file.url.deletingLastPathComponent()))
            // Another file previews as choosing it applies: whole, with no exceptions (#44894).
            let kept = name == themeFile?.name ? ThemeFileExceptionsSetting.keys(in: root) : []
            if let overlay {
                let held = Set(managedKeys.keys).union(kept)
                root = edit(overlay.applied(to: root, managed: held))
                // A previewed density row shows over the file's own density, as any previewed key over the file.
                let densityRows = [DensitySetting.configPath, CustomDensitySelectionSetting.configPath]
                themeDensity = edits.contains { densityRows.contains($0.0.path) } ? nil : overlay.density(under: held)
            }
        }
        var previewed = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                 validMetrics: SettingsApplier.validMetrics,
                                                 configDirectory: file.url.deletingLastPathComponent())
        previewed.themeDensity = themeDensity
        applier.apply(previewed)
        previewingKey = first.0.id
        previewSnapshot = previewed
        return true
    }

    /// The settings the terminal font and the surface backgrounds follow: the loaded ones, so a font
    /// size slider's preview never reloads Ghostty per tick, or the previewed ones while a Theme File
    /// previews (one hover shows a whole look, its terminal font included).
    public var lookFollowed: CmuxConfigSnapshot {
        previewingKey == ThemeFileSetting.configPath.joined(separator: ".") ? applied : snapshot
    }

    /// Ends a preview and restores the loaded settings.
    public func endPreview() {
        guard previewingKey != nil else { return }
        previewingKey = nil
        previewSnapshot = nil
        applier.apply(snapshot)
    }

    /// Writes the previewed value. The preview ends without restoring the
    /// old value, so the window keeps the new look until the reload
    /// applies the same value from the file.
    public func commitPreview(_ descriptor: SettingDescriptor, _ value: JSONValue?) async throws {
        do {
            try await setSetting(descriptor, to: value, by: .currentRun())
        } catch {
            endPreview()
            throw error
        }
        previewingKey = nil
        await reload()
        // A preview that started while the write reloaded keeps showing.
        if previewingKey == nil { previewSnapshot = nil }
    }

    /// `root` with `path` set to `value` (nil removes it), creating objects
    /// on the way.
    nonisolated static func replacing(_ path: [String], with value: JSONValue?, in root: JSONValue) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        var members: [String: JSONValue] = if case .object(let existing) = root { existing } else { [:] }
        if path.count == 1 {
            members[key] = value
        } else {
            members[key] = replacing(Array(path.dropFirst()), with: value, in: members[key] ?? .object([:]))
        }
        return .object(members)
    }
}

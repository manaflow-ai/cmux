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

    /// Shows every edit at once, one applied snapshot for all of them (the font picker's family,
    /// size and line height together). Refuses the whole set, returning false, when a key is
    /// managed or a value is one the schema refuses. An empty set ends the preview.
    @discardableResult
    public func preview(_ edits: [(descriptor: SettingDescriptor, value: JSONValue?)]) -> Bool {
        guard let first = edits.first else {
            endPreview()
            return true
        }
        for (descriptor, value) in edits {
            guard managedKeys[descriptor.id] == nil else { return false }
            if let value, !descriptor.accepts(value) { return false }
        }
        let linked = edits.flatMap { windowBackgroundLinkedEdits(writing: $0.descriptor.path, value: $0.value, in: snapshot.root) }
        func edit(_ root: JSONValue) -> JSONValue {
            // The write's linked keys preview with it (Opacity leaves Material "Ghostty").
            let edited = edits.reduce(root) { Self.replacing($1.descriptor.path, with: $1.value, in: $0) }
            return linked.reduce(edited) { Self.replacing($1.path, with: $1.value, in: $0) }
        }
        // From the settings under the theme file, so a previewed theme file replaces the active one.
        var root = edit(themeFile == nil ? snapshot.root : rootUnderThemeFile)
        if let name = ThemeFileSetting.name(in: root) {
            // The theme file applies (the last load's read: no disk read here), then the previewed
            // value over it, so a previewed key shows even where the file sets it.
            let overlay = name == themeFile?.name ? themeFile
                : ThemeFileOverlay(name: name, source: themeFileSources[name].map { .success($0) }, base: root,
                                   folder: ThemeFileSetting.folder(configDirectory: file.url.deletingLastPathComponent()))
            if let overlay { root = edit(overlay.applied(to: root, managed: Set(managedKeys.keys))) }
        }
        let previewed = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                 validMetrics: SettingsApplier.validMetrics,
                                                 configDirectory: file.url.deletingLastPathComponent())
        applier.apply(previewed)
        previewingKey = first.descriptor.id
        previewingKeys = Set(edits.map(\.descriptor.id))
        previewSnapshot = previewed
        return true
    }

    /// The keys whose preview the terminal shows when the font picker asks (`previewsTerminalFont`).
    public static let terminalFontPreviewKeys: Set<String> = ["terminal.fontFamily", "terminal.fontSize"]

    /// The settings the terminal font and the surface backgrounds follow: the loaded ones, so the
    /// Settings window's font size slider never reloads Ghostty per tick, or the previewed ones while
    /// a Theme File previews (one hover shows a whole look, its terminal font included) or the
    /// font picker previews the terminal font (one reload per step the person takes, which is the
    /// preview they asked to see).
    public var lookFollowed: CmuxConfigSnapshot {
        if previewingKey == ThemeFileSetting.configPath.joined(separator: ".") { return applied }
        if previewsTerminalFont, !previewingKeys.isEmpty, previewingKeys.isSubset(of: Self.terminalFontPreviewKeys) { return applied }
        return snapshot
    }

    /// Ends a preview and restores the loaded settings.
    public func endPreview() {
        guard previewingKey != nil else { return }
        previewingKey = nil
        previewingKeys = []
        previewsTerminalFont = false
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
        await finishCommit()
    }

    /// Writes every previewed edit in one publish and one reload (the font picker's family, size and
    /// line height), so the window never shows the new family with the old size between two writes.
    /// The preview ends without restoring the old values, as `commitPreview(_:_:)` does.
    public func commitPreview(_ edits: [(descriptor: SettingDescriptor, value: JSONValue?)]) async throws {
        do {
            try await setSettings(edits, by: .currentRun())
        } catch {
            endPreview()
            throw error
        }
        await finishCommit()
    }

    private func finishCommit() async {
        previewingKey = nil
        previewingKeys = []
        await reload()
        // A preview that started while the write reloaded keeps showing.
        if previewingKey == nil {
            previewsTerminalFont = false
            previewSnapshot = nil
        }
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

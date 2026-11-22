public import Foundation

/// A value the Settings window or a palette action tried to write that the
/// schema refuses (the app would load it with a diagnostic).
public nonisolated struct SettingRefused: Error, Sendable, CustomStringConvertible {
    public let key: String
    public let value: JSONValue
    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
    public var description: String { "\(key) does not accept \(value.compactText)" }
}

/// A write through `setSetting(at:to:by:)` for a key `SettingsSchema` does not list.
public struct SettingNotInSchema: Error, Sendable, CustomStringConvertible {
    public let key: String
    public var description: String { "\(key) is not a setting" }
}

extension SettingsController {
    /// Writes one schema setting atomically; nil, or the value the key has
    /// unset (`isUnsetValue`), removes the key (its default applies) and any
    /// object the removal leaves empty. The file
    /// watcher then applies the change to every window and the Settings
    /// window reads it back from `snapshot`.
    public func setSetting(_ descriptor: SettingDescriptor, to value: JSONValue?, by writer: SettingWriter) async throws {
        if let source = managedKeys[descriptor.id] { throw SettingManaged(key: descriptor.id, source: source) }
        guard writer.mayWrite(descriptor) else { throw SettingUserOnly(key: descriptor.id, writer: writer) }
        // A renamed key's old key goes with the write, so it can never apply
        // again behind the new value (or behind a reset to the default).
        var legacy: [[String]] = []
        for old in RenamedSettingKeys.legacyPaths(for: descriptor.path) {
            if try await file.value(at: old) != nil { legacy.append(old) }
        }
        if let value, !descriptor.accepts(value) { throw SettingRefused(key: descriptor.id, value: value) }
        // A write never copies the theme file's own entries into cmux-next.json (Theme Studio writes
        // the whole edits map it shows, which holds the file's colors).
        // The default's own value removes the key instead of storing it, so the key keeps following
        // the default when a later release changes it (a stored copy would pin the old one).
        // (`value = nil` on the optional, never a `nil` literal typed as `JSONValue`: that is `.null`,
        // which the file would store.)
        var value = strippingThemeFileEntries(descriptor, value)
        // A key the active theme file sets keeps an explicit value even at its default: removing
        // it would let the file's value apply again (#44894). Only a reset (nil) returns to the file.
        let overThemeFile = value != nil && setsInThemeFile(descriptor.id)
        if let written = value, !overThemeFile, isUnsetValue(written, of: descriptor) { value = nil }
        // The window background's opacity and material leave Ghostty, or return to it, together.
        // A material the active theme file sets stays the file's: Opacity alone moved (#44894).
        var linked = try await windowBackgroundLinkedEdits(writing: descriptor.path, value: value)
            .filter { !setsInThemeFile($0.path.joined(separator: ".")) }
        // Plain Backgrounds keeps every window opaque: the person's see-through Opacity or Material
        // turns it off with the write, so the value saves and draws (#44894).
        linked += plainBackgroundsOffEdits(writing: descriptor.path, value: value, by: writer)
        // A change to a key the active theme file sets applies over the file; a reset returns to it.
        if descriptor.path != ThemeFileExceptionsSetting.configPath {
            let writes = [(key: descriptor.id, sets: value != nil)] + linked.map { (key: $0.path.joined(separator: "."), sets: $0.value != nil) }
            var root = JSONValue.object([:])
            if let stored = try await file.value(at: ThemeFileExceptionsSetting.configPath) {
                root = Self.replacing(ThemeFileExceptionsSetting.configPath, with: stored, in: root)
            }
            let sameThemeFile = descriptor.path == ThemeFileSetting.configPath && value?.stringValue == themeFile?.name
            if !sameThemeFile, let exceptions = ThemeFileExceptionsSetting.edit(writing: writes, overlay: themeFile, in: root),
               managedKeys[ThemeFileExceptionsSetting.configPath.joined(separator: ".")] == nil {
                linked.append((path: ThemeFileExceptionsSetting.configPath, value: exceptions))
            }
        }
        // A built-in density (any write of appearance.density) ends the custom one, which would win
        // over it (plans/cmux-next/density-DESIGN.md).
        let customDensity = CustomDensitySelectionSetting.configPath
        if descriptor.path == DensitySetting.configPath, try await file.value(at: customDensity) != nil {
            linked.append((path: customDensity, value: nil))
        }
        // Before the write, so an observer of the new value already sees what the hook recorded;
        // the hook's undo runs if the write fails.
        let undo = writer == .user ? userWillWrite?(descriptor, value) : nil
        do {
            if let value {
                if !legacy.isEmpty || !linked.isEmpty {
                    try await file.apply([(path: descriptor.path, value: value)] + legacy.map { (path: $0, value: nil) } + linked)
                } else {
                    try await file.set(value, at: descriptor.path)
                }
                if descriptor.kind == .fontFamily, let family = value.stringValue { recentFonts.record(family) }
                await reloadAfterWrite()
            } else {
                for old in legacy { try await file.remove(old) }
                // One publish removes the pair; removePruning then drops the emptied parents.
                if !linked.isEmpty { try await file.apply([(path: descriptor.path, value: nil)] + linked) }
                try await removePruning(descriptor.path)
            }
        } catch {
            undo?()
            throw error
        }
        validatedWrites[descriptor.id, default: 0] += 1
    }

    /// `setSetting` for the schema key at `path`: the one write path of the
    /// palette's typed setters and handlers. Throws `SettingRetired` for a
    /// removed key and `SettingNotInSchema` when the schema lists no such key.
    public func setSetting(at path: [String], to value: JSONValue?, by writer: SettingWriter) async throws {
        if SettingsSchema.isRetired(path) {
            // Removing a retired key from an old file is allowed.
            if value == nil { return try await removePruning(path) }
            throw SettingRetired(key: path.joined(separator: "."))
        }
        guard let descriptor = SettingsSchema.descriptor(for: path) else {
            throw SettingNotInSchema(key: path.joined(separator: "."))
        }
        try await setSetting(descriptor, to: value, by: writer)
    }

    /// Advanced > Reset All Settings: removes every key the schema lists and
    /// every shortcut override. Custom actions, tab bar buttons, keys the
    /// schema does not know, `SettingsSchema.keptOnResetAll` (the theme and
    /// terminal font) and managed keys (edits refused) stay.
    public func resetAllSettings(by writer: SettingWriter) async throws {
        // Reset All changes user-only keys too: only the user may run it.
        guard writer == .user else { throw SettingUserOnly(key: "*", writer: writer) }
        let managed = file.managedGuard.managedKeys
        // One publish per batch, not one daemon write per key: a reset row drops the objects it
        // empties (cmux-config `remove_pruning`).
        var edits: [SettingsFileEdit] = []
        for descriptor in SettingsSchema.all where managed[descriptor.id] == nil && !SettingsSchema.keptOnResetAll.contains(descriptor.path) {
            edits.append(.reset(descriptor.path))
            // A renamed row's old key would apply again behind the reset (``RenamedSettingKeys``).
            for legacy in RenamedSettingKeys.legacyPaths(for: descriptor.path) { edits.append(.reset(legacy)) }
        }
        for key in SettingsSchema.retiredKeys.keys.sorted() where managed[key] == nil {
            edits.append(.reset(CmuxConfigFile.keyPath(from: key)))
        }
        edits.append(.reset(["shortcuts", "bindings"]))
        if case .object(let members)? = try await file.value(at: ["shortcuts"]) {
            let reserved = CmuxConfigSnapshot.reservedShortcutKeys
            for key in members.keys.sorted() where !reserved.contains(key) {
                edits.append(.reset(["shortcuts", key]))
            }
        }
        edits.append(.resetUnchanged(["shortcuts"], .object([:])))
        for start in stride(from: 0, to: edits.count, by: Self.editsPerWrite) {
            try await file.edit(Array(edits[start..<min(start + Self.editsPerWrite, edits.count)]))
        }
        await reloadAfterWrite()
    }

    /// The most edits one write sends (`settings.edit` takes at most 1000).
    nonisolated static let editsPerWrite = 1000

    /// Removes `path`, then each parent object that became empty.
    func removePruning(_ path: [String]) async throws {
        // Each parent goes only while it is still empty in the file the writer publishes, so an
        // object that gains a member meanwhile stays.
        let parents = (1..<max(path.count, 1)).reversed().map { SettingsFileEdit.resetUnchanged(Array(path.prefix($0)), .object([:])) }
        try await file.edit([.reset(path)] + parents)
        await reloadAfterWrite()
    }
}

extension SettingsController {
    /// Whether the active theme file sets `key` (dotted), so a write there needs an exception to apply.
    func setsInThemeFile(_ key: String) -> Bool {
        guard !ThemeFileExceptionsSetting.unexceptionable.contains(key) else { return false }
        return themeFile?.values.contains { $0.path.joined(separator: ".") == key } ?? false
    }
}

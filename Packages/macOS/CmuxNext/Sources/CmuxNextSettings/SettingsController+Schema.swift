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
        try await setSettings([(descriptor.path, value)], by: writer)
    }

    /// `setSetting` for the schema key at `path`: the one write path of the
    /// palette's typed setters and handlers. Throws `SettingRetired` for a
    /// removed key and `SettingNotInSchema` when the schema lists no such key.
    public func setSetting(at path: [String], to value: JSONValue?, by writer: SettingWriter) async throws {
        try await setSettings([(path, value)], by: writer)
    }

    /// Several `setSetting(at:to:by:)` writes, their linked edits included, in one publish and one
    /// reload: the watcher and every window see all of them or none, never a half-done look (a
    /// first-run pick, a preset). Each write is planned against the file as the ones before it
    /// leave it; any refusal refuses the whole batch before anything is written.
    public func setSettings(_ writes: [(path: [String], value: JSONValue?)], by writer: SettingWriter) async throws {
        guard !writes.isEmpty else { return }
        var root = try await file.document()
        var edits: [SettingsFileEdit] = []
        var undos: [@MainActor () -> Void] = []
        var written: [(descriptor: SettingDescriptor, value: JSONValue?)] = []
        do {
            for (path, value) in writes {
                let planned: [SettingsFileEdit]
                if SettingsSchema.isRetired(path) {
                    // Removing a retired key from an old file is allowed.
                    guard value == nil else { throw SettingRetired(key: path.joined(separator: ".")) }
                    planned = Self.removingPruned(path)
                } else {
                    guard let descriptor = SettingsSchema.descriptor(for: path) else {
                        throw SettingNotInSchema(key: path.joined(separator: "."))
                    }
                    let plan = try plannedWrite(descriptor, value, by: writer, in: root)
                    // Before the write, so an observer of the new value already sees what the hook
                    // recorded; the hook's undo runs if the write fails.
                    if writer == .user, let undo = userWillWrite?(descriptor, plan.value) { undos.append(undo) }
                    written.append((descriptor, plan.value))
                    planned = plan.edits
                }
                edits += planned
                root = Self.applying(planned, to: root)
            }
            try await file.edit(edits)
        } catch {
            for undo in undos.reversed() { undo() }
            throw error
        }
        for (descriptor, value) in written {
            if descriptor.kind == .fontFamily, let family = value?.stringValue { recentFonts.record(family) }
            validatedWrites[descriptor.id, default: 0] += 1
        }
        await reloadAfterWrite()
    }

    /// The edits one schema write publishes, read against `root` (the file as the writes before it
    /// leave it), and the value it stores (nil: the key goes).
    private func plannedWrite(_ descriptor: SettingDescriptor, _ value: JSONValue?, by writer: SettingWriter,
                              in root: JSONValue) throws -> (edits: [SettingsFileEdit], value: JSONValue?) {
        if let source = managedKeys[descriptor.id] { throw SettingManaged(key: descriptor.id, source: source) }
        guard writer.mayWrite(descriptor) else { throw SettingUserOnly(key: descriptor.id, writer: writer) }
        // A renamed key's old key goes with the write, so it can never apply
        // again behind the new value (or behind a reset to the default).
        let legacy = RenamedSettingKeys.legacyPaths(for: descriptor.path).filter { root.value(at: $0) != nil }
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
        var linked = windowBackgroundLinkedEdits(writing: descriptor.path, value: value, inFile: root)
            .filter { !setsInThemeFile($0.path.joined(separator: ".")) }
        // Plain Backgrounds keeps every window opaque: the person's see-through Opacity or Material
        // turns it off with the write, so the value saves and draws (#44894).
        linked += plainBackgroundsOffEdits(writing: descriptor.path, value: value, by: writer)
        // A change to a key the active theme file sets applies over the file; a reset returns to it.
        if descriptor.path != ThemeFileExceptionsSetting.configPath {
            let writes = [(key: descriptor.id, sets: value != nil)] + linked.map { (key: $0.path.joined(separator: "."), sets: $0.value != nil) }
            var exceptionsRoot = JSONValue.object([:])
            if let stored = root.value(at: ThemeFileExceptionsSetting.configPath) {
                exceptionsRoot = Self.replacing(ThemeFileExceptionsSetting.configPath, with: stored, in: exceptionsRoot)
            }
            let sameThemeFile = descriptor.path == ThemeFileSetting.configPath && value?.stringValue == themeFile?.name
            if !sameThemeFile, let exceptions = ThemeFileExceptionsSetting.edit(writing: writes, overlay: themeFile, in: exceptionsRoot),
               managedKeys[ThemeFileExceptionsSetting.configPath.joined(separator: ".")] == nil {
                linked.append((path: ThemeFileExceptionsSetting.configPath, value: exceptions))
            }
        }
        // A built-in density (any write of appearance.density) ends the custom one, which would win
        // over it (plans/cmux-next/density-DESIGN.md).
        let customDensity = CustomDensitySelectionSetting.configPath
        if descriptor.path == DensitySetting.configPath, root.value(at: customDensity) != nil {
            linked.append((path: customDensity, value: nil))
        }
        let others = legacy.map { SettingsFileEdit.reset($0) } + linked.map { edit -> SettingsFileEdit in
            if let value = edit.value { .set(edit.path, value) } else { .reset(edit.path) }
        }
        // A removal goes last, then each parent object it empties (cmux-config `remove_pruning`).
        guard let value else { return (others + Self.removingPruned(descriptor.path), nil) }
        return ([.set(descriptor.path, value)] + others, value)
    }

    /// Removes `path`, then each parent object that became empty: each parent goes only while it is
    /// still empty in the file the writer publishes, so an object that gains a member meanwhile stays.
    nonisolated static func removingPruned(_ path: [String]) -> [SettingsFileEdit] {
        [.reset(path)] + (1..<max(path.count, 1)).reversed().map { .resetUnchanged(Array(path.prefix($0)), .object([:])) }
    }

    /// `root` after `edits`, as the writer applies them (an emptied parent is left in place: the
    /// planner reads values, not empty objects).
    nonisolated static func applying(_ edits: [SettingsFileEdit], to root: JSONValue) -> JSONValue {
        edits.reduce(root) { root, edit in
            switch edit {
            case .set(let path, let value): replacing(path, with: value, in: root)
            case .setUnset(let path, let value): root.value(at: path) == nil ? replacing(path, with: value, in: root) : root
            case .reset(let path): root.value(at: path) == nil ? root : replacing(path, with: nil, in: root)
            case .resetUnchanged(let path, let value): root.value(at: path) == value ? replacing(path, with: nil, in: root) : root
            }
        }
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

    /// Settings' Reset <card> for a card that is no one schema group: `descriptors` back to their
    /// defaults in one publish, so the settings history records one change and one undo brings the
    /// card back. Managed keys stay (as in Reset All); a renamed row's old key goes too.
    public func resetSettings(_ descriptors: [SettingDescriptor], by writer: SettingWriter) async throws {
        let managed = file.managedGuard.managedKeys
        var edits: [SettingsFileEdit] = []
        for descriptor in descriptors where managed[descriptor.id] == nil {
            guard writer.mayWrite(descriptor) else { throw SettingUserOnly(key: descriptor.id, writer: writer) }
            edits.append(.reset(descriptor.path))
            for legacy in RenamedSettingKeys.legacyPaths(for: descriptor.path) { edits.append(.reset(legacy)) }
        }
        guard !edits.isEmpty else { return }
        try await file.edit(Array(edits.prefix(Self.editsPerWrite)))
        await reloadAfterWrite()
    }

    /// The most edits one write sends (`settings.edit` takes at most 1000).
    nonisolated static let editsPerWrite = 1000

    /// Removes `path`, then each parent object that became empty.
    func removePruning(_ path: [String]) async throws {
        try await file.edit(Self.removingPruned(path))
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

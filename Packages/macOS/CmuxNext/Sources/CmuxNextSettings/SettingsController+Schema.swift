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
    /// Writes one schema setting atomically; nil removes the key (its
    /// default applies) and any object the removal leaves empty. The file
    /// watcher then applies the change to every window and the Settings
    /// window reads it back from `snapshot`.
    public func setSetting(_ descriptor: SettingDescriptor, to value: JSONValue?, by writer: SettingWriter) async throws {
        if let source = managedKeys[descriptor.id] { throw SettingManaged(key: descriptor.id, source: source) }
        guard writer.mayWrite(descriptor) else { throw SettingUserOnly(key: descriptor.id, writer: writer) }
        // A renamed key's old key goes with the write, so it can never apply
        // again behind the new value (or behind a reset to the default).
        var legacy: [String]?
        if let old = RenamedSettingKeys.legacyPath(for: descriptor.path), try await file.value(at: old) != nil { legacy = old }
        // The window background's opacity and material leave Ghostty, or return to it, together.
        var linked = try await windowBackgroundLinkedEdits(writing: descriptor.path, value: value)
        // A built-in density (any write of appearance.density) ends the custom one, which would win
        // over it (plans/cmux-next/density-DESIGN.md).
        let customDensity = CustomDensitySelectionSetting().configPath
        if descriptor.path == DensitySetting().configPath, try await file.value(at: customDensity) != nil {
            linked.append((path: customDensity, value: nil))
        }
        if let value, !descriptor.accepts(value) { throw SettingRefused(key: descriptor.id, value: value) }
        // Before the write, so an observer of the new value already sees what the hook recorded;
        // the hook's undo runs if the write fails.
        let undo = writer == .user ? userWillWrite?(descriptor, value) : nil
        do {
            if let value {
                if legacy != nil || !linked.isEmpty {
                    try await file.apply([(path: descriptor.path, value: value)] + (legacy.map { [(path: $0, value: nil)] } ?? []) + linked)
                } else {
                    try await file.set(value, at: descriptor.path)
                }
                if descriptor.kind == .fontFamily, let family = value.stringValue { recentFonts.record(family) }
                await reloadAfterWrite()
            } else {
                if let legacy { try await file.remove(legacy) }
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
        for descriptor in SettingsSchema.all where managed[descriptor.id] == nil && !SettingsSchema.keptOnResetAll.contains(descriptor.path) {
            try await removePruning(descriptor.path)
        }
        for key in SettingsSchema.retiredKeys.keys.sorted() where managed[key] == nil {
            try await removePruning(CmuxConfigFile.keyPath(from: key))
        }
        try await file.remove(["shortcuts", "bindings"])
        if case .object(let members)? = try await file.value(at: ["shortcuts"]) {
            let reserved = CmuxConfigSnapshot.reservedShortcutKeys
            for key in members.keys where !reserved.contains(key) {
                try await file.remove(["shortcuts", key])
            }
        }
        try await pruneEmpty(["shortcuts"])
    }

    /// Removes `path`, then each parent object that became empty.
    func removePruning(_ path: [String]) async throws {
        try await file.remove(path)
        var parent = Array(path.dropLast())
        while !parent.isEmpty {
            guard try await pruneEmpty(parent) else { break }
            parent.removeLast()
        }
        await reloadAfterWrite()
    }

    /// Removes the object at `path` when it has no members. True when removed.
    @discardableResult
    private func pruneEmpty(_ path: [String]) async throws -> Bool {
        guard case .object(let members)? = try await file.value(at: path), members.isEmpty else { return false }
        try await file.remove(path)
        return true
    }
}

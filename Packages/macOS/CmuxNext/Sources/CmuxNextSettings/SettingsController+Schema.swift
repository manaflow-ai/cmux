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

/// A write through `setSetting(at:to:)` for a key `SettingsSchema` does not list.
public struct SettingNotInSchema: Error, Sendable, CustomStringConvertible {
    public let key: String
    public var description: String { "\(key) is not a setting" }
}

extension SettingsController {
    /// Writes one schema setting atomically; nil removes the key (its
    /// default applies) and any object the removal leaves empty. The file
    /// watcher then applies the change to every window and the Settings
    /// window reads it back from `snapshot`.
    public func setSetting(_ descriptor: SettingDescriptor, to value: JSONValue?) async throws {
        if let source = managedKeys[descriptor.id] { throw SettingManaged(key: descriptor.id, source: source) }
        if let value {
            guard descriptor.accepts(value) else { throw SettingRefused(key: descriptor.id, value: value) }
            try await file.set(value, at: descriptor.path)
            await reloadAfterWrite()
        } else {
            try await removePruning(descriptor.path)
        }
        validatedWrites[descriptor.id, default: 0] += 1
    }

    /// `setSetting` for the schema key at `path`: the one write path of the
    /// palette's typed setters and handlers. Throws `SettingRetired` for a
    /// removed key and `SettingNotInSchema` when the schema lists no such key.
    public func setSetting(at path: [String], to value: JSONValue?) async throws {
        if SettingsSchema.isRetired(path) {
            // Removing a retired key from an old file is allowed.
            if value == nil { return try await removePruning(path) }
            throw SettingRetired(key: path.joined(separator: "."))
        }
        guard let descriptor = SettingsSchema.descriptor(for: path) else {
            throw SettingNotInSchema(key: path.joined(separator: "."))
        }
        try await setSetting(descriptor, to: value)
    }

    /// Advanced > Reset All Settings: removes every key the schema lists and
    /// every shortcut override. Custom actions, tab bar buttons, keys the
    /// schema does not know, `SettingsSchema.keptOnResetAll` (the theme and
    /// terminal font) and managed keys (edits refused) stay.
    public func resetAllSettings() async throws {
        let managed = file.managedGuard.managedKeys
        for descriptor in SettingsSchema.all where managed[descriptor.id] == nil && !SettingsSchema.keptOnResetAll.contains(descriptor.path) {
            try await removePruning(descriptor.path)
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

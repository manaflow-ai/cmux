public import Foundation

/// A value the Settings window or a palette action tried to write that the
/// schema refuses (the app would load it with a diagnostic).
public nonisolated struct SettingRefused: Error, Sendable, CustomStringConvertible {
    public let key: String
    public let value: JSONValue
    public var description: String { "\(key) does not accept \(value.compactText)" }
}

extension SettingsController {
    /// Writes one schema setting atomically; nil removes the key (its
    /// default applies) and any object the removal leaves empty. The file
    /// watcher then applies the change to every window and the Settings
    /// window reads it back from `snapshot`.
    public func setSetting(_ descriptor: SettingDescriptor, to value: JSONValue?) async throws {
        if let source = managedKeys[descriptor.id] { throw SettingManaged(key: descriptor.id, source: source) }
        guard let value else { return try await removePruning(descriptor.path) }
        guard descriptor.accepts(value) else { throw SettingRefused(key: descriptor.id, value: value) }
        try await file.set(value, at: descriptor.path)
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
            guard try await pruneEmpty(parent) else { return }
            parent.removeLast()
        }
    }

    /// Removes the object at `path` when it has no members. True when removed.
    @discardableResult
    private func pruneEmpty(_ path: [String]) async throws -> Bool {
        guard case .object(let members)? = try await file.value(at: path), members.isEmpty else { return false }
        try await file.remove(path)
        return true
    }
}

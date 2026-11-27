import Foundation

/// A decoded shortcut-binding map plus every action ID managed by that map.
///
/// Shortcut values are decoded independently so one malformed binding cannot
/// hide valid siblings. ``managedActionIDs`` retains malformed entries as
/// managed, allowing consumers to suppress lower-precedence legacy values.
public struct ShortcutBindingsSnapshot: Sendable, Equatable, SettingCodable {
    /// Successfully decoded bindings, keyed by shortcut action ID.
    public let bindings: [String: StoredShortcut]

    /// Every action ID present in the persisted map, including invalid entries.
    public let managedActionIDs: Set<String>

    /// Creates a shortcut-binding snapshot.
    ///
    /// - Parameters:
    ///   - bindings: Successfully decoded shortcut bindings.
    ///   - managedActionIDs: Every action ID present in the persisted map.
    public init(
        bindings: [String: StoredShortcut],
        managedActionIDs: Set<String>
    ) {
        self.bindings = bindings
        self.managedActionIDs = managedActionIDs
    }

    /// Decodes a property-list binding map while retaining every action ID.
    public static func decodeFromUserDefaults(_ raw: Any?) -> ShortcutBindingsSnapshot? {
        decode(raw, using: StoredShortcut.decodeFromUserDefaults(_:))
    }

    /// Encodes the successfully decoded bindings for property-list storage.
    public func encodeForUserDefaults() -> Any {
        bindings.mapValues { $0.encodeForUserDefaults() }
    }

    /// Decodes a JSON binding map while retaining every action ID.
    public static func decodeFromJSON(_ raw: Any?) -> ShortcutBindingsSnapshot? {
        decode(raw, using: StoredShortcut.decodeFromJSON(_:))
    }

    /// Encodes the successfully decoded bindings for JSON storage.
    public func encodeForJSON() -> Any {
        bindings.mapValues { $0.encodeForJSON() }
    }

    private static func decode(
        _ raw: Any?,
        using decodeValue: (Any?) -> StoredShortcut?
    ) -> ShortcutBindingsSnapshot? {
        guard let dictionary = raw as? [String: Any] else { return nil }

        var bindings: [String: StoredShortcut] = [:]
        bindings.reserveCapacity(dictionary.count)
        for (actionID, rawValue) in dictionary {
            bindings[actionID] = decodeValue(rawValue)
        }
        return ShortcutBindingsSnapshot(
            bindings: bindings,
            managedActionIDs: Set(dictionary.keys)
        )
    }
}

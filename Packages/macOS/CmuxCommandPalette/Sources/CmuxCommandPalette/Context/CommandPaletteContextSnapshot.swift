import Foundation

/// Immutable snapshot of the bool/string context values that gate which
/// palette commands are visible and enabled.
public struct CommandPaletteContextSnapshot {
    private var boolValues: [String: Bool] = [:]
    private var stringValues: [String: String] = [:]

    /// Creates an empty snapshot.
    public init() {}

    /// Sets a boolean context value.
    public mutating func setBool(_ key: CommandPaletteContextKeys, _ value: Bool) {
        boolValues[key.rawValue] = value
    }

    /// Sets a string context value; nil or empty removes the key.
    public mutating func setString(_ key: CommandPaletteContextKeys, _ value: String?) {
        guard let value, !value.isEmpty else {
            stringValues.removeValue(forKey: key.rawValue)
            return
        }
        stringValues[key.rawValue] = value
    }

    /// Reads a boolean context value (false when absent).
    public func bool(_ key: CommandPaletteContextKeys) -> Bool {
        boolValues[key.rawValue] ?? false
    }

    /// Reads a string context value.
    public func string(_ key: CommandPaletteContextKeys) -> String? {
        stringValues[key.rawValue]
    }

    /// Order-insensitive fingerprint over all context values, used to detect
    /// when the command list must be rebuilt. Hash values are only compared
    /// within the current process.
    public func fingerprint() -> Int {
        Self.fingerprint(boolValues: boolValues, stringValues: stringValues)
    }

    /// Fingerprints raw bool/string context dictionaries.
    public static func fingerprint(
        boolValues: [String: Bool],
        stringValues: [String: String]
    ) -> Int {
        var hasher = Hasher()
        for key in boolValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(boolValues[key] ?? false)
        }
        for key in stringValues.keys.sorted() {
            hasher.combine(key)
            hasher.combine(stringValues[key] ?? "")
        }
        return hasher.finalize()
    }
}

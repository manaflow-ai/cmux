import Foundation

/// An immutable snapshot of the context keys a ``ShortcutWhenClause`` evaluates
/// against during keyboard-shortcut dispatch.
///
/// The app target builds one of these per key event from its current focus and UI
/// state (writing plain `Bool`/`String`/`Int` values keyed by
/// ``ShortcutContextKnownKey`` names), then evaluates each candidate action's
/// clause against it. Because it is a frozen `Sendable` value, it can be cached
/// per `NSEvent` and read without crossing actor boundaries.
///
/// Reads follow VS Code semantics: an absent key, or a key whose value is the
/// wrong type for the requested accessor, reads as "false / nil" rather than
/// trapping.
///
/// ```swift
/// var context = ShortcutContext()
/// context.setBool(ShortcutContextKnownKey.commandPaletteVisible.rawValue, true)
/// ShortcutWhenClause.parse("commandPaletteVisible")?.evaluate(context) // true
/// ```
public struct ShortcutContext: Equatable, Sendable {
    private var values: [String: ShortcutContextValue]

    /// Creates an empty context (every key reads as absent).
    public init() {
        values = [:]
    }

    /// Creates a context from an explicit key-to-value map.
    ///
    /// - Parameter values: The context key names mapped to their values.
    public init(values: [String: ShortcutContextValue]) {
        self.values = values
    }

    /// Sets a boolean context value.
    ///
    /// - Parameters:
    ///   - key: The context key name (typically a ``ShortcutContextKnownKey`` raw value).
    ///   - value: The boolean value.
    public mutating func setBool(_ key: String, _ value: Bool) {
        values[key] = .bool(value)
    }

    /// Sets a string context value.
    ///
    /// - Parameters:
    ///   - key: The context key name.
    ///   - value: The string value.
    public mutating func setString(_ key: String, _ value: String) {
        values[key] = .string(value)
    }

    /// Sets an integer context value.
    ///
    /// - Parameters:
    ///   - key: The context key name.
    ///   - value: The integer value.
    public mutating func setInt(_ key: String, _ value: Int) {
        values[key] = .int(value)
    }

    /// The raw value for a key, or `nil` when the key is absent.
    ///
    /// - Parameter key: The context key name.
    /// - Returns: The stored ``ShortcutContextValue``, or `nil`.
    public func value(for key: String) -> ShortcutContextValue? {
        values[key]
    }

    /// The boolean value for a key, defaulting to `false` when absent or non-boolean.
    ///
    /// - Parameter key: The context key name.
    /// - Returns: The boolean value, or `false`.
    public func bool(_ key: String) -> Bool {
        values[key]?.boolValue ?? false
    }

    /// The string value for a key, or `nil` when absent or non-string.
    ///
    /// - Parameter key: The context key name.
    /// - Returns: The string value, or `nil`.
    public func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    /// The integer value for a key, or `nil` when absent or non-integer.
    ///
    /// - Parameter key: The context key name.
    /// - Returns: The integer value, or `nil`.
    public func int(_ key: String) -> Int? {
        values[key]?.intValue
    }
}

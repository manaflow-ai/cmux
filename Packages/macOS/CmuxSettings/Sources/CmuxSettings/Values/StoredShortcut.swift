import Foundation

/// A shortcut binding as it lives on disk: one or two ``ShortcutStroke``s.
///
/// A single-stroke binding fires when the user presses the recorded
/// modifiers + key. A two-stroke ("chord") binding is the tmux-style
/// prefix pattern: press the first stroke, then the second within a
/// short window. ``isUnbound`` represents an explicit "no shortcut for
/// this action" assignment so users can suppress an inherited default.
public struct StoredShortcut: Sendable, Equatable, Hashable, Codable, SettingCodable {
    /// The primary stroke. Empty `key` means the shortcut is unbound.
    public let first: ShortcutStroke

    /// Optional second stroke (chord). `nil` means single-stroke.
    public let second: ShortcutStroke?

    /// A binding that explicitly clears any inherited default.
    public static let unbound = StoredShortcut(
        first: ShortcutStroke(key: "")
    )

    public init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.first = first
        self.second = second
    }

    private enum CodingKeys: String, CodingKey {
        case first
        case second
    }

    /// Decodes the current nested format or the flat format written by cmux 0.64.10 and earlier.
    ///
    /// - Parameter decoder: The decoder containing a persisted shortcut binding.
    /// - Throws: A decoding error when the payload matches neither supported format or contains
    ///   invalid field values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.first) {
            first = try container.decode(ShortcutStroke.self, forKey: .first)
            second = try container.decodeIfPresent(ShortcutStroke.self, forKey: .second)
            return
        }

        self = try LegacyStoredShortcutPayload(from: decoder).storedShortcut
    }

    /// True when this binding is the explicit "no shortcut" marker.
    public var isUnbound: Bool { first.key.isEmpty && second == nil }

    /// True when the binding fires on two consecutive strokes.
    public var hasChord: Bool { second != nil }

    /// Returns the binding with both strokes using canonical persisted keys.
    public func canonicalized() -> StoredShortcut {
        StoredShortcut(first: first.canonicalized(), second: second?.canonicalized())
    }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> StoredShortcut? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decodeFromJSON(_ raw: Any?) -> StoredShortcut? {
        guard let raw else { return nil }
        if raw is NSNull { return .unbound }
        if let string = raw as? String {
            return parseConfig(string, allowBareFirstStroke: true)
        }
        if let strings = raw as? [String] {
            return strings.isEmpty
                ? .unbound
                : parseConfig(strokes: strings, allowBareFirstStroke: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}

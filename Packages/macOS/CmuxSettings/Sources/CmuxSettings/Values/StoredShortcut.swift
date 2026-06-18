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

    /// True when this binding is the explicit "no shortcut" marker.
    public var isUnbound: Bool { first.key.isEmpty && second == nil }

    /// True when the binding fires on two consecutive strokes.
    public var hasChord: Bool { second != nil }

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
        // Accept every binding shape the cmux.json contract supports (matching
        // the app's `KeyboardShortcutSettingsFileStore`), so reading
        // `shortcuts.bindings` through this typed path never silently drops a
        // user's string/array-form overrides:
        //   null              -> explicitly unbound
        //   "cmd+t"           -> single stroke
        //   ["ctrl+b", "c"]   -> chord
        //   { "first": {…} }  -> the package recorder's object form
        // Decode is lenient (`allowBareFirstStroke: true`) so a valid bare-key
        // binding (e.g. a diff-viewer `j`) is preserved rather than discarded.
        if raw is NSNull { return .unbound }
        if let string = raw as? String {
            return parseConfig(string, allowBareFirstStroke: true)
        }
        if let array = raw as? [Any] {
            let strokes = array.compactMap { $0 as? String }
            guard strokes.count == array.count else { return nil }
            return strokes.isEmpty ? .unbound : parseConfig(strokes: strokes, allowBareFirstStroke: true)
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

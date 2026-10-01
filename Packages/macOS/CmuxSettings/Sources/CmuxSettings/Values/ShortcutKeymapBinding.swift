import Foundation

/// One `shortcuts.bindings` value in its hand-editable `cmux.json` form:
/// `"cmd+d"`, `["ctrl+b", "c"]`, or `null`.
///
/// Keymap presets write this form instead of the structured
/// ``StoredShortcut`` encoding so the file stays readable, and compare
/// through ``shortcut`` so either form on disk matches.
public enum ShortcutKeymapBinding: Sendable, Hashable, SettingCodable {
    /// A single stroke such as `"cmd+shift+c"`.
    case stroke(String)
    /// A prefix stroke followed by a second stroke, such as `["ctrl+b", "c"]`.
    case chord(String, String)
    /// An explicit unbind (`null`).
    case unbound

    /// The parsed binding, or `nil` when the text is not a valid shortcut.
    public var shortcut: StoredShortcut? {
        switch self {
        case .stroke(let stroke):
            return StoredShortcut.parseConfig(stroke, allowBareFirstStroke: true)?.canonicalized()
        case .chord(let prefix, let second):
            return StoredShortcut.parseConfig(
                strokes: [prefix, second],
                allowBareFirstStroke: true
            )?.canonicalized()
        case .unbound:
            return .unbound
        }
    }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> ShortcutKeymapBinding? {
        decodeFromJSON(raw)
    }

    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    public static func decodeFromJSON(_ raw: Any?) -> ShortcutKeymapBinding? {
        if raw is NSNull { return .unbound }
        if let stroke = raw as? String { return .stroke(stroke) }
        if let strokes = raw as? [String] {
            switch strokes.count {
            case 1: return .stroke(strokes[0])
            case 2: return .chord(strokes[0], strokes[1])
            default: return nil
            }
        }
        return nil
    }

    public func encodeForJSON() -> Any {
        switch self {
        case .stroke(let stroke):
            return stroke
        case .chord(let prefix, let second):
            return [prefix, second]
        case .unbound:
            return NSNull()
        }
    }
}

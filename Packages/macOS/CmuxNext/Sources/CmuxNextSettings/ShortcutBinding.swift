import Foundation

/// One keystroke from cmux.json, independent of the action registry's types
/// so parsing can run off the main actor. `key` uses NSMenuItem
/// key-equivalent semantics (lowercase character or function-key character),
/// the same as `CmuxNextActions.Shortcut`.
public struct ShortcutStrokeSpec: Sendable, Hashable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

/// A parsed `shortcuts.bindings.<actionID>` value.
public enum ShortcutBinding: Sendable, Hashable {
    /// The user removed the shortcut (`null`, `""`, `none`, `clear`,
    /// `unbound`, `disabled`, or the recorder's empty-key object).
    case unbound
    case stroke(ShortcutStrokeSpec)
    /// A two-stroke chord (`["ctrl+b", "c"]`); the first key needs Command
    /// or Control.
    case chord(ShortcutStrokeSpec, ShortcutStrokeSpec)
    /// Several keys for one action (`{"any": ["ctrl+tab", "cmd+]"]}`), each
    /// a `.stroke` or a `.chord`, at least two, none twice. The first is the
    /// one menus show.
    case alternates([ShortcutBinding])
}

extension ShortcutBinding {
    /// The keys this binding gives an action, in order (none when unbound).
    public var keys: [ShortcutBinding] {
        switch self {
        case .unbound: []
        case .stroke, .chord: [self]
        case .alternates(let bindings): bindings
        }
    }
}

/// Reads and writes the cmux.json shortcut formats: `"cmd+shift+p"`, `["ctrl+b", "c"]`, the unbind
/// tokens, the Settings recorder's object form and next's alternates (`{"any": [...]}`). Rust answers
/// (cmux-config app_ops/shortcut.rs, `shortcut.*`); this keeps only the wire mapping.
public struct ShortcutBindingFormat {
    public init() {}

    /// Parses one binding value. Nil when the value is not a valid binding.
    public static func parse(_ value: JSONValue) -> ShortcutBinding? {
        binding(SettingsRust.answer("shortcut.parse", ["value": value])["binding"])
    }

    /// The cmux.json value for `binding`, in the forms ``parse(_:)`` reads:
    /// `"cmd+]"`, `["ctrl+b", "c"]`, `{"any": [...]}`, or null.
    public static func configValue(_ binding: ShortcutBinding) -> JSONValue {
        SettingsRust.answer("shortcut.config_value", ["binding": json(binding)])["value"] ?? .null
    }

    /// Parses `cmd+shift+p`, `⌘⇧P`-style modifier tokens joined by `+`.
    public static func parseStroke(_ text: String) -> ShortcutStrokeSpec? {
        stroke(SettingsRust.answer("shortcut.parse_stroke", ["text": .string(text)])["stroke"])
    }

    /// Maps a config key token to a key-equivalent character.
    static func keyEquivalent(forToken rawToken: String) -> String? {
        SettingsRust.answer("shortcut.key_equivalent", ["token": .string(rawToken)])["key"]?.stringValue
    }

    /// The config string for a stroke (`cmd+shift+p`), as the Settings
    /// writer stores it.
    public static func configString(_ stroke: ShortcutStrokeSpec) -> String {
        SettingsRust.answer("shortcut.config_string", ["stroke": json(stroke)])["text"]?.stringValue ?? ""
    }

    static func configToken(forKey key: String) -> String {
        SettingsRust.answer("shortcut.config_token", ["key": .string(key)])["token"]?.stringValue ?? key
    }

    private static func stroke(_ value: JSONValue?) -> ShortcutStrokeSpec? {
        guard let value, let key = value["key"]?.stringValue else { return nil }
        return ShortcutStrokeSpec(
            key: key, command: value["command"]?.boolValue ?? false, shift: value["shift"]?.boolValue ?? false,
            option: value["option"]?.boolValue ?? false, control: value["control"]?.boolValue ?? false
        )
    }

    private static func binding(_ value: JSONValue?) -> ShortcutBinding? {
        guard let value else { return nil }
        if value["unbound"]?.boolValue == true { return .unbound }
        if let one = value["stroke"] { return stroke(one).map(ShortcutBinding.stroke) }
        if let pair = value["chord"]?.arrayValue, pair.count == 2, let first = stroke(pair[0]), let second = stroke(pair[1]) {
            return .chord(first, second)
        }
        guard let items = value["any"]?.arrayValue else { return nil }
        let bindings = items.compactMap(binding)
        return bindings.count == items.count ? .alternates(bindings) : nil
    }

    private static func json(_ stroke: ShortcutStrokeSpec) -> JSONValue {
        ["key": .string(stroke.key), "command": .bool(stroke.command), "shift": .bool(stroke.shift),
         "option": .bool(stroke.option), "control": .bool(stroke.control)]
    }

    private static func json(_ binding: ShortcutBinding) -> JSONValue {
        switch binding {
        case .unbound: ["unbound": .bool(true)]
        case .stroke(let one): ["stroke": json(one)]
        case .chord(let first, let second): ["chord": .array([json(first), json(second)])]
        case .alternates(let bindings): ["any": .array(bindings.map(json))]
        }
    }
}

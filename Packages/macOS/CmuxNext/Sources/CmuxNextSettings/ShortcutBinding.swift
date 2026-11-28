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
    /// One key or one chord: what an `{"any": [...]}` item may be.
    var isKey: Bool {
        switch self {
        case .stroke, .chord: true
        case .unbound, .alternates: false
        }
    }

    /// The keys this binding gives an action, in order (none when unbound).
    public var keys: [ShortcutBinding] {
        switch self {
        case .unbound: []
        case .stroke, .chord: [self]
        case .alternates(let bindings): bindings
        }
    }
}

/// Reads and writes the cmux.json shortcut formats the old app accepts:
/// `"cmd+shift+p"`, `["ctrl+b", "c"]`, the unbind tokens, and the Settings
/// recorder's object form `{ "first": { "key": "p", "command": true, ... } }`;
/// plus next's alternates, `{"any": [...]}` with one of those keys or chords
/// per item (`{"any": ["ctrl+tab", "cmd+]", ["ctrl+b", "n"]]}`). The parse,
/// the key names and the canonical form are Rust's (`shortcut.*` ops,
/// cmux-config app_ops/shortcut.rs); this keeps the AppKit-facing enum.
public struct ShortcutBindingFormat {
    public init() {}

    /// Parses one binding value. Nil when the value is not a valid binding.
    public static func parse(_ value: JSONValue) -> ShortcutBinding? {
        SettingsRust.answer("shortcut.parse", .object(["value": value]))["binding"].flatMap(binding(wire:))
    }

    /// ``parse(_:)`` for many values in one call, in order.
    public static func parseMany(_ values: [JSONValue]) -> [ShortcutBinding?] {
        let reply = SettingsRust.answer("shortcut.parse_many", .object(["values": .array(values)]))
        let bindings = reply["bindings"]?.arrayValue ?? []
        guard bindings.count == values.count else { return values.map { _ in nil } }
        return bindings.map(binding(wire:))
    }

    /// The cmux.json value for `binding`, in the forms ``parse(_:)`` reads:
    /// `"cmd+]"`, `["ctrl+b", "c"]`, `{"any": [...]}`, or null.
    public static func configValue(_ binding: ShortcutBinding) -> JSONValue {
        SettingsRust.answer("shortcut.config_value", .object(["binding": wire(binding)]))["value"] ?? .null
    }

    /// Parses `cmd+shift+p`, `⌘⇧P`-style modifier tokens joined by `+`.
    public static func parseStroke(_ text: String) -> ShortcutStrokeSpec? {
        SettingsRust.answer("shortcut.parse_stroke", .object(["text": .string(text)]))["stroke"].flatMap(stroke(wire:))
    }

    /// Maps a config key token to a key-equivalent character.
    static func keyEquivalent(forToken rawToken: String) -> String? {
        SettingsRust.answer("shortcut.key_equivalent", .object(["token": .string(rawToken)]))["key"]?.stringValue
    }

    /// The config string for a stroke (`cmd+shift+p`), as the Settings
    /// writer stores it.
    public static func configString(_ stroke: ShortcutStrokeSpec) -> String {
        SettingsRust.answer("shortcut.config_string", .object(["stroke": wire(stroke)]))["text"]?.stringValue ?? ""
    }

    static func configToken(forKey key: String) -> String {
        SettingsRust.answer("shortcut.config_token", .object(["key": .string(key)]))["token"]?.stringValue ?? key
    }

    // MARK: The ops' wire shapes

    /// `{key, command, shift, option, control}`.
    static func wire(_ stroke: ShortcutStrokeSpec) -> JSONValue {
        .object(["key": .string(stroke.key), "command": .bool(stroke.command), "shift": .bool(stroke.shift),
                 "option": .bool(stroke.option), "control": .bool(stroke.control)])
    }

    /// `{"unbound": true}`, `{"stroke": S}`, `{"chord": [S, S]}` or `{"any": [B, ...]}`.
    static func wire(_ binding: ShortcutBinding) -> JSONValue {
        switch binding {
        case .unbound: .object(["unbound": .bool(true)])
        case .stroke(let stroke): .object(["stroke": wire(stroke)])
        case .chord(let first, let second): .object(["chord": .array([wire(first), wire(second)])])
        case .alternates(let bindings): .object(["any": .array(bindings.map(wire))])
        }
    }

    static func stroke(wire value: JSONValue) -> ShortcutStrokeSpec? {
        guard let key = value["key"]?.stringValue else { return nil }
        return ShortcutStrokeSpec(key: key, command: value["command"]?.boolValue ?? false,
                                  shift: value["shift"]?.boolValue ?? false,
                                  option: value["option"]?.boolValue ?? false,
                                  control: value["control"]?.boolValue ?? false)
    }

    static func binding(wire value: JSONValue) -> ShortcutBinding? {
        if value["unbound"]?.boolValue == true { return .unbound }
        if let stroke = value["stroke"] { return Self.stroke(wire: stroke).map(ShortcutBinding.stroke) }
        if let chord = value["chord"]?.arrayValue {
            guard chord.count == 2, let first = stroke(wire: chord[0]), let second = stroke(wire: chord[1]) else { return nil }
            return .chord(first, second)
        }
        guard let any = value["any"]?.arrayValue else { return nil }
        let bindings = any.compactMap(binding(wire:))
        return bindings.count == any.count ? .alternates(bindings) : nil
    }
}

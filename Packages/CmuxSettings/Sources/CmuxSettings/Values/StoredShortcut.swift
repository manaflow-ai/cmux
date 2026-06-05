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

    /// Decodes the current nested shape and transparently recovers the legacy
    /// flat shape persisted by cmux ≤ 0.64.10 (top-level `key` / `command` / …
    /// / `chord*` fields). Without this, every shortcut a user customized
    /// before the move to nested ``ShortcutStroke``s fails to decode and
    /// silently reverts to its default.
    /// See https://github.com/manaflow-ai/cmux/issues/5422.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let first = try container.decodeIfPresent(ShortcutStroke.self, forKey: .first) {
            self.first = first
            self.second = try container.decodeIfPresent(ShortcutStroke.self, forKey: .second)
            return
        }
        let legacy = try LegacyFlatShortcut(from: decoder)
        self.first = legacy.firstStroke
        self.second = legacy.secondStroke
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
        guard let raw, !(raw is NSNull) else { return nil }
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

/// The pre-0.64.11 on-disk shape of ``StoredShortcut``: the primary stroke's
/// fields flat at the top level plus optional `chord*` fields for a second
/// stroke. Decoded only as a fallback by ``StoredShortcut/init(from:)`` so
/// bindings persisted before the move to nested ``ShortcutStroke``s survive.
/// See https://github.com/manaflow-ai/cmux/issues/5422.
private struct LegacyFlatShortcut: Decodable {
    let firstStroke: ShortcutStroke
    let secondStroke: ShortcutStroke?

    private enum CodingKeys: String, CodingKey {
        case key, command, shift, option, control, keyCode
        case chordKey, chordCommand, chordShift, chordOption, chordControl, chordKeyCode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `key` is the legacy discriminator: every legacy value has it (an
        // unbound binding is `key == ""`). Its absence means the payload is
        // neither the new nor the legacy shape, so decoding throws and the
        // caller falls back to the action's default binding.
        let key = try c.decode(String.self, forKey: .key)
        firstStroke = ShortcutStroke(
            key: key,
            command: try c.decodeIfPresent(Bool.self, forKey: .command) ?? false,
            shift: try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false,
            option: try c.decodeIfPresent(Bool.self, forKey: .option) ?? false,
            control: try c.decodeIfPresent(Bool.self, forKey: .control) ?? false,
            keyCode: try c.decodeIfPresent(UInt16.self, forKey: .keyCode)
        )
        if let chordKey = try c.decodeIfPresent(String.self, forKey: .chordKey), !chordKey.isEmpty {
            secondStroke = ShortcutStroke(
                key: chordKey,
                command: try c.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false,
                shift: try c.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false,
                option: try c.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false,
                control: try c.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false,
                keyCode: try c.decodeIfPresent(UInt16.self, forKey: .chordKeyCode)
            )
        } else {
            secondStroke = nil
        }
    }
}

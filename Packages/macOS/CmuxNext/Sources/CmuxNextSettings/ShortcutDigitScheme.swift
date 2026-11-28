import Foundation

/// What Ctrl-1...9 select (R85, Lawrence 2026-10-04): tabs by default (the
/// common editor behavior) with Spaces on Ctrl-Opt-1...9, or Spaces on
/// Ctrl-1...9 with tabs on Ctrl-Opt-1...9. Onboarding offers the choice and
/// writes the scheme's overrides into cmux.json `shortcuts.bindings` the way a
/// base keymap does (`ShortcutKeymapPreset`); keybindings.json and Settings can
/// change each binding later. Rust holds the bindings and plans the switch
/// (cmux-config app_ops/keymap.rs, `keymap.digit_plan` and `keymap.digit_active`).
public nonisolated enum ShortcutDigitScheme: String, CaseIterable, Sendable {
    case tabs
    case spaces

    /// The edits that switch `bindings` (cmux.json `shortcuts.bindings`) to
    /// this scheme. A scheme owns a digit binding that is absent or equal to
    /// what some scheme gives it (compared parsed, so `opt+ctrl+1` counts);
    /// any other value (a keymap preset's Cmd-1, a chord) was set by hand,
    /// stays, and is listed in `kept`.
    public func plan(from bindings: [String: JSONValue]) -> ShortcutDigitSchemePlan {
        let reply = SettingsRust.answer("keymap.digit_plan", ["scheme": .string(rawValue), "bindings": .object(bindings)])
        let (changes, kept, edits) = ShortcutKeymapPlan.decode(reply)
        return ShortcutDigitSchemePlan(scheme: self, changes: changes, kept: kept, edits: edits)
    }

    /// The scheme `bindings` is on: switching to it changes nothing and it
    /// keeps nothing. Nil when a digit binding was set by hand.
    public static func active(in bindings: [String: JSONValue]) -> ShortcutDigitScheme? {
        SettingsRust.answer("keymap.digit_active", ["bindings": .object(bindings)])["scheme"]?.stringValue.flatMap(Self.init(rawValue:))
    }
}

/// The `shortcuts.bindings` edits that switch cmux.json to a digit scheme.
public nonisolated struct ShortcutDigitSchemePlan: Sendable, Equatable {
    public let scheme: ShortcutDigitScheme
    /// Each edit: the value to write, or nil to remove the override.
    public let changes: [ShortcutKeymapPlan.Change]
    /// Digit actions the user bound by hand (another value), left alone.
    public let kept: [String]
    /// The file edits that apply ``changes``.
    public let edits: [ShortcutKeymapPlan.Edit]

    public var isEmpty: Bool { changes.isEmpty }
}

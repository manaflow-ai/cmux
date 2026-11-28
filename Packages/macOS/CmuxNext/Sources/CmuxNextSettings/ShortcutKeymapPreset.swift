import Foundation

/// A base keymap for people coming from another terminal (the old app's
/// Settings > Keyboard Shortcuts > Base Keymap): `shortcuts.bindings`
/// overrides, each different from the cmux default, so the cmux preset has
/// none and choosing it removes what another preset wrote. Shortcuts a
/// terminal shares with cmux (iTerm2's Cmd-D, Cmd-T) need no override.
/// Rust holds each preset's bindings and plans the switch (cmux-config
/// app_ops/keymap.rs, `keymap.plan` and `keymap.active`).
public nonisolated enum ShortcutKeymapPreset: String, CaseIterable, Sendable {
    /// cmux's built-in shortcuts.
    case cmux
    /// iTerm2: Cmd-1…9 selects tabs, Cmd-Opt-1…9 workspaces, Cmd-Shift-C
    /// copy mode, Cmd-Ctrl-arrows resize panes.
    case iTerm2 = "iterm2"
    /// Terminal.app: Cmd-Opt-W closes other tabs, Cmd-Shift-I renames a tab.
    case terminal
    /// tmux's `ctrl+b` prefix, tmux windows as workspaces and panes as panes.
    case tmux

    /// The edits that switch `bindings` (cmux.json `shortcuts.bindings`) to
    /// this preset. A preset replaces only bindings that are absent or that
    /// some preset wrote; one the user set by hand stays and is listed in
    /// `kept`. Ownership is inferred from values, as in the old app: a
    /// binding typed by hand that equals a preset's value counts as the
    /// preset's.
    public func plan(from bindings: [String: JSONValue]) -> ShortcutKeymapPlan {
        let reply = SettingsRust.answer("keymap.plan", ["preset": .string(rawValue), "bindings": .object(bindings)])
        return ShortcutKeymapPlan(preset: self, reply: reply)
    }

    /// The preset `bindings` is on: switching to it changes nothing and at
    /// least one of its overrides is there (cmux when none is). Nil when the
    /// file mixes presets.
    public static func active(in bindings: [String: JSONValue]) -> ShortcutKeymapPreset? {
        SettingsRust.answer("keymap.active", ["bindings": .object(bindings)])["preset"]?.stringValue.flatMap(Self.init(rawValue:))
    }
}

/// The `shortcuts.bindings` edits that switch cmux.json to a keymap preset.
public nonisolated struct ShortcutKeymapPlan: Sendable, Equatable {
    public nonisolated struct Change: Sendable, Equatable {
        public let actionID: String
        /// The value to write, or nil to remove the override so the cmux
        /// default applies again.
        public let write: JSONValue?

        public init(actionID: String, write: JSONValue?) {
            self.actionID = actionID
            self.write = write
        }
    }

    /// One file edit that applies a plan: the value at `path`, or nil to remove it.
    public nonisolated struct Edit: Sendable, Equatable {
        public let path: [String]
        public let value: JSONValue?
    }

    public let preset: ShortcutKeymapPreset
    public let changes: [Change]
    /// Actions the preset would change but the user set by hand, left alone.
    public let kept: [String]
    /// The file edits that apply ``changes``; a removed override also goes
    /// from the legacy `shortcuts.<id>` form.
    public let edits: [Edit]

    public var isEmpty: Bool { changes.isEmpty }

    init(preset: ShortcutKeymapPreset, reply: JSONValue) {
        self.preset = preset
        (changes, kept, edits) = Self.decode(reply)
    }

    /// A `keymap.plan` or `keymap.digit_plan` reply's changes, kept actions and edits.
    static func decode(_ reply: JSONValue) -> ([Change], [String], [Edit]) {
        let changes = reply["changes"]?.arrayValue?.compactMap { change in
            change["action"]?.stringValue.map { Change(actionID: $0, write: change["write"]) }
        } ?? []
        let kept = reply["kept"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let edits = reply["edits"]?.arrayValue?.compactMap { edit in
            edit["path"]?.arrayValue.map { Edit(path: $0.compactMap(\.stringValue), value: edit["value"]) }
        } ?? []
        return (changes, kept, edits)
    }
}

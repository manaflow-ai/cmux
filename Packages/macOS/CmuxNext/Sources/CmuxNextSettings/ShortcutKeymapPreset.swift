import Foundation

/// A base keymap for people coming from another terminal (the old app's
/// Settings > Keyboard Shortcuts > Base Keymap): `shortcuts.bindings`
/// overrides, each different from the cmux default, so the cmux preset has
/// none and choosing it removes what another preset wrote. Shortcuts a
/// terminal shares with cmux (iTerm2's Cmd-D, Cmd-T) need no override.
public nonisolated enum ShortcutKeymapPreset: String, CaseIterable, Sendable {
    /// cmux's built-in shortcuts.
    case cmux
    /// iTerm2: Cmd-1…9 selects tabs, Cmd-Opt-1…9 workspaces, Cmd-Shift-C
    /// copy mode, Cmd-Ctrl-arrows resize panes.
    case iTerm2 = "iterm2"
    /// Terminal.app: Cmd-Opt-W closes other tabs, Cmd-Shift-I renames a tab
    /// (New Agent Chat moves to Ctrl-Cmd-Shift-I).
    case terminal
    /// tmux's `ctrl+b` prefix, tmux windows as workspaces and panes as panes.
    case tmux

    /// The bindings this preset writes, in the hand-editable cmux.json forms
    /// (`"cmd+1"`, `["ctrl+b", "c"]`) so the file stays readable.
    public var overrides: KeyValuePairs<String, JSONValue> {
        switch self {
        case .cmux:
            return [:]
        case .iTerm2:
            return [
                "selectSurfaceByNumber": "cmd+1",
                "selectWorkspaceByNumber": "cmd+opt+1",
                "toggleTerminalCopyMode": "cmd+shift+c",
                "resizePaneLeft": "cmd+ctrl+left",
                "resizePaneRight": "cmd+ctrl+right",
                "resizePaneUp": "cmd+ctrl+up",
                "resizePaneDown": "cmd+ctrl+down",
            ]
        case .terminal:
            return [
                "closeOtherTabsInPane": "cmd+opt+w",
                "renameTab": "cmd+shift+i",
                // Rename takes New Agent Chat's Cmd-Shift-I, so the chat moves over.
                "palette.newAgentChat": "ctrl+cmd+shift+i",
            ]
        case .tmux:
            return [
                "newTab": ["ctrl+b", "c"],
                "closeTab": ["ctrl+b", "x"],
                "closeWorkspace": ["ctrl+b", "shift+7"],
                "nextSidebarTab": ["ctrl+b", "n"],
                "prevSidebarTab": ["ctrl+b", "p"],
                "selectWorkspaceByNumber": ["ctrl+b", "1"],
                "renameWorkspace": ["ctrl+b", ","],
                "goToWorkspace": ["ctrl+b", "w"],
                "splitRight": ["ctrl+b", "shift+5"],
                "splitDown": ["ctrl+b", "shift+'"],
                "focusLeft": ["ctrl+b", "left"],
                "focusRight": ["ctrl+b", "right"],
                "focusUp": ["ctrl+b", "up"],
                "focusDown": ["ctrl+b", "down"],
                "focusNextPane": ["ctrl+b", "o"],
                "toggleSplitZoom": ["ctrl+b", "z"],
                "toggleTerminalCopyMode": ["ctrl+b", "["],
            ]
        }
    }

    func binding(for actionID: String) -> ShortcutBinding? {
        overrides.first { $0.key == actionID }.flatMap { ShortcutBindingFormat.parse($0.value) }
    }

    /// This preset's actions in its order, then every other action some
    /// preset changes.
    var actionIDs: [String] {
        var seen = Set<String>()
        return (overrides.map(\.key) + Self.allCases.flatMap { $0.overrides.map(\.key) }).filter { seen.insert($0).inserted }
    }

    /// The edits that switch `bindings` (cmux.json `shortcuts.bindings`) to
    /// this preset. A preset replaces only bindings that are absent or that
    /// some preset wrote; one the user set by hand stays and is listed in
    /// `kept`. Ownership is inferred from values, as in the old app: a
    /// binding typed by hand that equals a preset's value counts as the
    /// preset's.
    public func plan(from bindings: [String: JSONValue]) -> ShortcutKeymapPlan {
        var changes: [ShortcutKeymapPlan.Change] = []
        var kept: [String] = []
        for id in actionIDs {
            let current = bindings[id].flatMap(ShortcutBindingFormat.parse)
            let ownedByPreset = current.map { value in Self.allCases.contains { $0.binding(for: id) == value } } ?? false
            if let target = overrides.first(where: { $0.key == id }) {
                guard current != ShortcutBindingFormat.parse(target.value) else { continue }
                guard bindings[id] == nil || ownedByPreset else {
                    kept.append(id)
                    continue
                }
                changes.append(.init(actionID: id, write: target.value))
            } else if ownedByPreset {
                changes.append(.init(actionID: id, write: nil))
            }
        }
        return ShortcutKeymapPlan(preset: self, changes: changes, kept: kept)
    }

    /// The preset `bindings` is on: switching to it changes nothing and at
    /// least one of its overrides is there (cmux when none is). Nil when the
    /// file mixes presets.
    public static func active(in bindings: [String: JSONValue]) -> ShortcutKeymapPreset? {
        for preset in allCases where preset != .cmux {
            let applied = preset.overrides.contains { bindings[$0.key].flatMap(ShortcutBindingFormat.parse) == ShortcutBindingFormat.parse($0.value) }
            if applied, preset.plan(from: bindings).isEmpty { return preset }
        }
        return cmux.plan(from: bindings).isEmpty ? .cmux : nil
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

    public let preset: ShortcutKeymapPreset
    public let changes: [Change]
    /// Actions the preset would change but the user set by hand, left alone.
    public let kept: [String]

    public var isEmpty: Bool { changes.isEmpty }
}

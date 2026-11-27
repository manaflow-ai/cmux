import Foundation

/// What Ctrl-1...9 select (R85, Lawrence 2026-10-04): tabs by default (the
/// common editor behavior) with Spaces on Ctrl-Opt-1...9, or Spaces on
/// Ctrl-1...9 with tabs on Ctrl-Opt-1...9. Onboarding offers the choice and
/// writes ``overrides`` into cmux.json `shortcuts.bindings` the way a base
/// keymap does (`ShortcutKeymapPreset`); keybindings.json and Settings can
/// change each binding later.
public nonisolated enum ShortcutDigitScheme: String, CaseIterable, Sendable {
    case tabs
    case spaces

    /// The bindings this scheme writes; the default scheme writes none, and
    /// choosing it removes what the other one wrote.
    public var overrides: KeyValuePairs<String, JSONValue> {
        switch self {
        case .tabs:
            return [:]
        case .spaces:
            return ["space.selectByNumber": "ctrl+1", "selectSurfaceByNumber": "ctrl+opt+1"]
        }
    }

    /// The action ids a scheme may write (removed when switching to ``tabs``).
    public static let actionIDs = ["space.selectByNumber", "selectSurfaceByNumber"]

    /// The catalog defaults of the digit actions (the tabs scheme), so a
    /// binding typed by hand that equals one counts as the scheme's.
    static let catalogDefaults: [String: JSONValue] = ["space.selectByNumber": "ctrl+opt+1", "selectSurfaceByNumber": "ctrl+1"]

    /// The binding this scheme gives `actionID` (its override, else the default).
    func binding(for actionID: String) -> ShortcutBinding? {
        (overrides.first { $0.key == actionID }?.value ?? Self.catalogDefaults[actionID]).flatMap(ShortcutBindingFormat.parse)
    }

    /// The edits that switch `bindings` (cmux.json `shortcuts.bindings`) to
    /// this scheme. A scheme owns a digit binding that is absent or equal to
    /// what some scheme gives it (compared parsed, so `opt+ctrl+1` counts);
    /// any other value (a keymap preset's Cmd-1, a chord) was set by hand,
    /// stays, and is listed in `kept`.
    public func plan(from bindings: [String: JSONValue]) -> ShortcutDigitSchemePlan {
        var changes: [ShortcutKeymapPlan.Change] = []
        var kept: [String] = []
        for id in Self.actionIDs {
            let current = bindings[id].flatMap(ShortcutBindingFormat.parse)
            // What the action has now: its binding, else the catalog default.
            guard (current ?? Self.catalogDefaults[id].flatMap(ShortcutBindingFormat.parse)) != binding(for: id) else { continue }
            let target = overrides.first { $0.key == id }?.value
            guard bindings[id] == nil || Self.owns(id, current) else {
                kept.append(id)
                continue
            }
            changes.append(.init(actionID: id, write: target))
        }
        return ShortcutDigitSchemePlan(scheme: self, changes: changes, kept: kept)
    }

    /// The scheme `bindings` is on: switching to it changes nothing and it
    /// keeps nothing. Nil when a digit binding was set by hand.
    public static func active(in bindings: [String: JSONValue]) -> ShortcutDigitScheme? {
        allCases.first { scheme in
            let plan = scheme.plan(from: bindings)
            return plan.isEmpty && plan.kept.isEmpty
        }
    }

    /// `current` on `actionID` is a value some scheme gives it.
    private static func owns(_ actionID: String, _ current: ShortcutBinding?) -> Bool {
        guard let current else { return false }
        return allCases.contains { $0.binding(for: actionID) == current }
    }
}

/// The `shortcuts.bindings` edits that switch cmux.json to a digit scheme.
public nonisolated struct ShortcutDigitSchemePlan: Sendable, Equatable {
    public let scheme: ShortcutDigitScheme
    /// Each edit: the value to write, or nil to remove the override.
    public let changes: [ShortcutKeymapPlan.Change]
    /// Digit actions the user bound by hand (another value), left alone.
    public let kept: [String]

    public var isEmpty: Bool { changes.isEmpty }
}

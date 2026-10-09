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

    /// The edits that switch `bindings` (cmux.json `shortcuts.bindings`) to
    /// this scheme.
    public func plan(from bindings: [String: JSONValue]) -> ShortcutDigitSchemePlan {
        ShortcutDigitSchemePlan(scheme: self, changes: [], kept: [])
    }

    /// The scheme `bindings` is on; nil when a digit binding was set by hand.
    public static func active(in bindings: [String: JSONValue]) -> ShortcutDigitScheme? {
        nil
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

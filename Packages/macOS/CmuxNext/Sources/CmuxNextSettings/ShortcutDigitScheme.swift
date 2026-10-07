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
}

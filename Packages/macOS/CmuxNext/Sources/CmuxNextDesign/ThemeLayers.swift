import Foundation

/// Where a theme comes from, broadest first (plans/cmux-next/data-model.md 6).
public nonisolated enum ThemeLevel: Int, Sendable, Comparable, CaseIterable {
    /// The Ghostty config (plus `appearance.theme` in cmux.json).
    case config
    /// The room a window shows: the whole window.
    case room
    /// One workspace: its content area only.
    case workspace
    /// One terminal: its surface only.
    case terminal

    public static func < (lhs: ThemeLevel, rhs: ThemeLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The theme specs set at each level for one terminal (or one workspace,
/// with `terminal` nil). Precedence: terminal, workspace, room, Ghostty
/// config. Pure, so the rule is testable without views.
public nonisolated struct ThemeLayers: Hashable, Sendable {
    public var room: ThemeSpec?
    public var workspace: ThemeSpec?
    public var terminal: ThemeSpec?

    public init(room: ThemeSpec? = nil, workspace: ThemeSpec? = nil, terminal: ThemeSpec? = nil) {
        self.room = room
        self.workspace = workspace
        self.terminal = terminal
    }

    /// Stored text to specs; text that does not parse counts as unset, so a
    /// bad value falls back to the next level instead of breaking colors.
    public static func parsing(room: String?, workspace: String?, terminal: String?) -> ThemeLayers {
        ThemeLayers(room: room.flatMap(ThemeSpec.init), workspace: workspace.flatMap(ThemeSpec.init),
                    terminal: terminal.flatMap(ThemeSpec.init))
    }

    /// The spec that colors `level` and the level it comes from. A nil
    /// spec means the Ghostty config (source `.config`).
    public func effective(at level: ThemeLevel) -> (spec: ThemeSpec?, source: ThemeLevel) {
        if level >= .terminal, let terminal { return (terminal, .terminal) }
        if level >= .workspace, let workspace { return (workspace, .workspace) }
        if level >= .room, let room { return (room, .room) }
        return (nil, .config)
    }

    /// The spec set at exactly `level`, ignoring inheritance.
    public func own(_ level: ThemeLevel) -> ThemeSpec? {
        switch level {
        case .config: nil
        case .room: room
        case .workspace: workspace
        case .terminal: terminal
        }
    }
}

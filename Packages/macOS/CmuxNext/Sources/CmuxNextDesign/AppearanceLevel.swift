/// One level of the appearance cascade (plans/cmux-next/appearance-scopes-DESIGN.md), least to
/// most specific: a value at a later level overrides every earlier one.
public nonisolated enum AppearanceLevel: Int, CaseIterable, Comparable, Sendable {
    /// cmux.json `appearance.*` and the Ghostty config.
    case app
    /// A space (room): every window showing it.
    case window
    /// One workspace.
    case workspace
    /// An `appearance.rules` entry matching what runs (folder, repo, host, agent).
    case rule
    /// One pane.
    case pane
    /// One terminal or page tab.
    case tab

    /// The CLI and menu name of the level.
    public var name: String {
        switch self {
        case .app: "app"
        case .window: "window"
        case .workspace: "workspace"
        case .rule: "rule"
        case .pane: "pane"
        case .tab: "tab"
        }
    }

    /// The level a CLI or menu names (`window`, `workspace`, `pane`, `tab`); nil for others.
    public init?(name: String) {
        guard let level = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = level
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

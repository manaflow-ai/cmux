/// `sidebar.density` (cx-13w3; Lawrence 2026-10-14): normal rows (the default since 2026-11-02, the
/// Codex desktop sidebar of https://github.com/manaflow-ai/cmux/issues/28793: "the default for the sidebar
/// text should be the codex text size"), ultra-compact, compact and comfortable rows (Normal's rows at
/// a smaller or larger ``scale``), or
/// expanded ones (T3 Code / Codex style): a dim preview line under the title, the time since the last
/// change, and a line for the pull request and computer. Minimal mode (`sidebar.minimal`) is a separate
/// toggle on top of any density.
public nonisolated enum SidebarDensity: String, Hashable, Sendable, CaseIterable {
    case ultraCompact
    case compact
    case normal
    case comfortable
    case expanded

    /// How large this density draws the sidebar against Normal. One factor sizes rows, text, insets,
    /// icons, corners and gaps together (``SidebarRowTokens``), so the densities are the same design at
    /// four sizes, 10% apart. Expanded is Normal's size with a second line.
    public var scale: Double {
        switch self {
        case .ultraCompact: 0.8
        case .compact: 0.9
        case .normal, .expanded: 1
        case .comfortable: 1.1
        }
    }
}

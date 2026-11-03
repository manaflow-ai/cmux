/// `sidebar.density` (cx-13w3; Lawrence 2026-10-14): normal rows (the default since 2026-11-02, the
/// Codex desktop sidebar of https://github.com/manaflow-ai/cmux/issues/28793: "the default for the sidebar
/// text should be the codex text size"), compact rows (the smaller rows from before Normal, kept exactly
/// for whoever picked them), comfortable rows (Normal on taller rows with more space around them), or
/// expanded ones (T3 Code / Codex style): a dim preview line under the title, the time since the last
/// change, and a line for the pull request and computer. Minimal mode (`sidebar.minimal`) is a separate
/// toggle on top of any density.
public nonisolated enum SidebarDensity: String, Hashable, Sendable, CaseIterable {
    case compact
    case normal
    case comfortable
    case expanded
}

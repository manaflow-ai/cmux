/// `sidebar.density` (cx-13w3; Lawrence 2026-10-14): compact rows (one
/// line, the default), comfortable rows (one line on taller rows with more
/// space around them, `SidebarLayoutMetrics.comfortable`), or expanded ones
/// (T3 Code / Codex style): a dim preview line under the title, the time
/// since the last change, and a line for the pull request and computer.
/// Minimal mode (`sidebar.minimal`) is a separate toggle on top of any density.
public nonisolated enum SidebarDensity: String, Hashable, Sendable, CaseIterable {
    case compact
    case comfortable
    case expanded
}

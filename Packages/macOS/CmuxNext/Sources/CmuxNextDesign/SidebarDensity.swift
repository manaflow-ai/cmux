/// `sidebar.density` (cx-13w3): compact rows (one line, the default) or
/// expanded ones (T3 Code / Codex style): a dim preview line under the
/// title, the time since the last change, and a line for the pull request
/// and computer.
public nonisolated enum SidebarDensity: String, Hashable, Sendable, CaseIterable {
    case compact
    case expanded
}

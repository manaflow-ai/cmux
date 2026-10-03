/// cmux.json `layout.stickyColumnEdge` and `layout.stickyColumnMode`: what
/// Dock Column and a tab moved to a new sticky column use when the command
/// names no edge or mode. `nearest` (the default) is Dock Column's own
/// rule: the edge the column is nearer to (plans/cmux-next/layout-model.md).
public nonisolated enum StickyDefaultEdge: String, Hashable, Sendable, CaseIterable {
    case nearest, left, right, top, bottom
}

public nonisolated enum StickyDefaultMode: String, Hashable, Sendable, CaseIterable {
    case docked, overlay
}

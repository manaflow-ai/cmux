/// cmux.json `layout.dockColumnEdge` and `layout.dockColumnMode`: what
/// Dock Column and a tab moved to a new docked column use when the command
/// names no edge or mode. `nearest` (the default) is Dock Column's own
/// rule: the edge the column is nearer to (plans/cmux-next/layout-model.md).
public nonisolated enum DockDefaultEdge: String, Hashable, Sendable, CaseIterable {
    case nearest, left, right, top, bottom
}

public nonisolated enum DockDefaultMode: String, Hashable, Sendable, CaseIterable {
    case docked, overlay
}

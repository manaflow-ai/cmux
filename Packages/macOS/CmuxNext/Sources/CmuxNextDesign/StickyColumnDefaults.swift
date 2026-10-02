/// cmux.json `layout.stickyColumnEdge` and `layout.stickyColumnMode`: what
/// Make Column Sticky uses when the column is not sticky yet and the
/// command names no edge or mode.
public nonisolated enum StickyDefaultEdge: String, Hashable, Sendable, CaseIterable {
    case left, right
}

public nonisolated enum StickyDefaultMode: String, Hashable, Sendable, CaseIterable {
    case docked, overlay
}

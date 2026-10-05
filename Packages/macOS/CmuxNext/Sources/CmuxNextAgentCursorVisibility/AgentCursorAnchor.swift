/// Where the hidden-target indicator of an agent cursor sits.
public nonisolated enum AgentCursorAnchor: Equatable, Hashable, Sendable {
    /// A background tab: its chip in the pane's strip.
    case tabChip
    /// A background tab with no laid-out chip (a collapsed tab group): the strip.
    case tabStrip
    /// The target's column (or row) is scrolled out of view: the strip edge
    /// on that side.
    case columnEdge(AgentCursorEdge)
    /// Another workspace of the same window: its sidebar row.
    case workspaceRow
    /// No better anchor (sidebar hidden, workspace not listed in the
    /// sidebar, pane not on the active screen): the leading window edge.
    case windowEdge
}

public nonisolated enum AgentCursorEdge: String, Codable, Equatable, Hashable, Sendable {
    case leading, trailing, top, bottom
}

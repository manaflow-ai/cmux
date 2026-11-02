/// Where the hidden-target indicator of an agent cursor sits.
public nonisolated enum AgentCursorAnchor: Equatable, Hashable, Sendable {
    /// A background tab: its chip in the pane's strip.
    case tabChip
    /// A background tab with no laid-out chip (a collapsed tab group): the strip.
    case tabStrip
    /// The target's column (or row) is scrolled out of view: the strip edge
    /// on that side.
    case columnEdge(AgentCursorEdge)
    /// Another workspace of the same window: its sidebar row (the Home item
    /// for the home workspace, which the workspace list leaves out).
    case workspaceRow
    /// No better anchor (sidebar hidden, workspace not listed in the
    /// sidebar, pane not on the active screen): the leading window edge.
    case windowEdge

    /// The name on the wire (the Rust rules' answer, the debug socket):
    /// `tabChip`, `tabStrip`, `columnEdge.<side>`, `workspaceRow`, `windowEdge`.
    public var wireName: String {
        switch self {
        case .tabChip: "tabChip"
        case .tabStrip: "tabStrip"
        case let .columnEdge(side): "columnEdge.\(side.rawValue)"
        case .workspaceRow: "workspaceRow"
        case .windowEdge: "windowEdge"
        }
    }

    public init?(wireName: String) {
        switch wireName {
        case "tabChip": self = .tabChip
        case "tabStrip": self = .tabStrip
        case "workspaceRow": self = .workspaceRow
        case "windowEdge": self = .windowEdge
        default:
            let prefix = "columnEdge."
            guard wireName.hasPrefix(prefix), let side = AgentCursorEdge(rawValue: String(wireName.dropFirst(prefix.count))) else {
                return nil
            }
            self = .columnEdge(side)
        }
    }
}

public nonisolated enum AgentCursorEdge: String, Codable, Equatable, Hashable, Sendable {
    case leading, trailing, top, bottom
}

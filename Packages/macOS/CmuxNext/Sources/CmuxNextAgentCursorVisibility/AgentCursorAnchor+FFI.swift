/// The anchor's name on the wire of cmux-focus-core's `agent_cursor_visibility`
/// answer (and the debug socket): `tabChip`, `tabStrip`, `columnEdge.<side>`,
/// `workspaceRow`, `windowEdge`.
nonisolated extension AgentCursorAnchor {
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

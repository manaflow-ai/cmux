/// Where a terminal agent's fork opens its new terminal (``AgentForkDestination``), as the daemon
/// commands that make it: a split of the agent's pane (then swapped to put the fork first on the
/// left or top), a strip column on either side of the pane's column (`new-column`, `left` with
/// `column-left-v1`), a row below the pane's row (`new-row`, `rows-v1`), a tab in the pane, or a
/// new workspace (a new window shows that workspace).
public enum TerminalForkPlacement: Equatable, Sendable {
    /// A split of the agent's pane: right when not `down`; `swap` puts the fork left or above.
    case split(down: Bool, swap: Bool)
    /// A new strip column after the pane's column, or before it when `left`.
    case column(left: Bool)
    /// A new row below the pane's row, in its column.
    case row
    /// A new tab in the agent's pane.
    case tab
    /// A new workspace (for a new window too, which then shows it).
    case workspace

    /// The placement that opens a terminal fork at `destination`.
    /// - Parameter destination: Where the person asked the fork to open.
    public init(_ destination: AgentForkDestination) {
        switch destination {
        case .right: self = .split(down: false, swap: false)
        case .left: self = .split(down: false, swap: true)
        case .down: self = .split(down: true, swap: false)
        case .up: self = .split(down: true, swap: true)
        case .columnRight: self = .column(left: false)
        case .columnLeft: self = .column(left: true)
        case .row: self = .row
        case .tab: self = .tab
        case .workspace, .window: self = .workspace
        }
    }
}

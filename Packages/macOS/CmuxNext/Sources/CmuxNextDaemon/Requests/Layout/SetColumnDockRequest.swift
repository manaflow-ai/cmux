import Foundation

/// Pins the column holding `pane` to a viewport edge, or unpins it
/// (`dock-columns-v1`). One docked column per edge: the daemon unpins a
/// column already on that edge, and refuses to leave no column scrolling.
/// `role` needs `dock-column-role-v1`; an older daemon ignores it.
public struct SetColumnDockRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-column-dock"
    public static let requiredCapability: String? = DaemonCapabilities.shared.dockColumns
    public var pane: PaneID
    public var dock: Bool
    public var edge: String?
    public var mode: String?
    public var role: String?
    public var transaction: UInt64?
    public init(pane: PaneID, dock: DockSnapshot?, transaction: UInt64? = nil) {
        self.pane = pane
        self.dock = dock != nil
        self.edge = dock?.edge.rawValue
        self.mode = dock?.mode.rawValue
        self.role = dock?.role?.rawValue
        self.transaction = transaction
    }
}

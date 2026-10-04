import Foundation

/// Pins the column holding `pane` to a viewport edge, or unpins it
/// (`sticky-columns-v1`). One docked column per edge: the daemon unpins a
/// column already on that edge, and refuses to leave no column scrolling.
public struct SetColumnDockRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-column-sticky"
    public var pane: PaneID
    public var dock: Bool
    public var edge: String?
    public var mode: String?
    public var transaction: UInt64?
    // TODO(R87 slice 2): wire key `dock` once the daemon renames it.
    enum CodingKeys: String, CodingKey { case pane, dock = "sticky", edge, mode, transaction }
    public init(pane: PaneID, dock: DockSnapshot?, transaction: UInt64? = nil) {
        self.pane = pane
        self.dock = dock != nil
        self.edge = dock?.edge.rawValue
        self.mode = dock?.mode.rawValue
        self.transaction = transaction
    }
}

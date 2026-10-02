import Foundation

/// Pins the column holding `pane` to a viewport edge, or unpins it
/// (`sticky-columns-v1`). One sticky column per edge: the daemon unpins a
/// column already on that edge, and refuses to leave no column scrolling.
public struct SetColumnStickyRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-column-sticky"
    public var pane: PaneID
    public var sticky: Bool
    public var edge: String?
    public var mode: String?
    public var transaction: UInt64?
    public init(pane: PaneID, sticky: StickySnapshot?, transaction: UInt64? = nil) {
        self.pane = pane
        self.sticky = sticky != nil
        self.edge = sticky?.edge.rawValue
        self.mode = sticky?.mode.rawValue
        self.transaction = transaction
    }
}

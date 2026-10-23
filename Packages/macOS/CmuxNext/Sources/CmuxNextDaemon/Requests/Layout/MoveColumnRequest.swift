import Foundation

/// Moves the whole viewport column holding `pane` (every pane, split and
/// row in it) one place left or right (`column-move-v1`). The daemon refuses
/// a column at the strip's edge or next to a docked column
/// (`column-move-edge`) and a docked column (`column-move-docked`).
public struct MoveColumnRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "move-column"
    public static let requiredCapability: String? = DaemonCapability.columnMove.rawValue
    /// Any pane of the column that moves.
    public var pane: PaneID
    public var direction: ColumnMoveDirection
    public init(pane: PaneID, direction: ColumnMoveDirection) {
        self.pane = pane
        self.direction = direction
    }
}

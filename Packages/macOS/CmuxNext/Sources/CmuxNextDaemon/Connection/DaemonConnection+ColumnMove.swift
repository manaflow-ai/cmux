import Foundation

extension DaemonConnection {
    /// Moves the whole column holding `pane` one place in `direction`
    /// (`move-column`, `column-move-v1`). Throws `missingCapabilities` on a
    /// daemon without it; nothing is sent then.
    public func moveColumn(of pane: PaneID, direction: ColumnMoveDirection) async throws {
        _ = try await request(MoveColumnRequest(pane: pane, direction: direction))
    }
}

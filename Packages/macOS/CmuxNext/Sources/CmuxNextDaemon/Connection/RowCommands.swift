import Foundation

/// Row commands (plans/cmux-next/rows.md) on one connection. Both need
/// `rows-v1`; a daemon without it gets no request. A separate type keeps
/// `DaemonConnection` within its size ratchet.
public struct RowCommands: Sendable {
    let connection: DaemonConnection

    public init(_ connection: DaemonConnection) { self.connection = connection }

    /// New row below `pane`'s row in its column, `height` permille tall.
    @discardableResult
    public func newRow(below pane: PaneID, height: Int, options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        try await requireRows()
        guard await connection.supportsPlacementEnv else {
            return try await connection.request(NewRowRequest(pane: pane, height: height, options: await connection.served(options)))
        }
        let options = await connection.placed(options)
        return DaemonConnection.created(try await connection.request(NewRowRequest(pane: pane, height: height, options: options)), options: options)
    }

    /// Every row height of `column` (`set-row-heights`).
    public func setRowHeights(column: ColumnID, heights: [RowHeightValue], fit: Bool, transaction: UInt64? = nil) async throws {
        try await requireRows()
        _ = try await connection.request(SetRowHeightsRequest(column: column, heights: heights, fit: fit, transaction: transaction))
    }

    private func requireRows() async throws {
        guard await connection.identity?.supports(DaemonCapabilities.shared.rows) == true else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.rows])
        }
    }
}

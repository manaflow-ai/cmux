import Foundation

/// Row commands (plans/cmux-next/rows.md) on one connection. Both need
/// `rows-v1`; a daemon without it gets no request. A separate type keeps
/// `DaemonConnection` within its size ratchet.
public struct RowCommands: Sendable {
    let connection: DaemonConnection

    public init(_ connection: DaemonConnection) { self.connection = connection }

    /// A `set-row-heights` transaction. The daemon echoes it as a decimal
    /// string in the commit's `screen-changed` delta, so it doubles as the
    /// store intent's transaction; random, so no two workspaces or
    /// connections share one. Below 2^53, so JSON tools keep it exact.
    public static func makeTransaction() -> UInt64 { UInt64.random(in: 1...(1 << 53)) }

    /// New row below `pane`'s row in its column, `height` permille tall.
    @discardableResult
    public func newRow(below pane: PaneID, height: Int, options: SpawnOptions = SpawnOptions()) async throws -> SurfaceCreated {
        try await requireRows()
        guard await connection.supportsPlacementEnv else {
            return try await connection.request(NewRowRequest(pane: pane, height: height, options: await connection.served(options)))
        }
        let options = await connection.placed(options)
        // A row's stand-in (`row-client-keys-v1`) waits for its reply or the connection's end, never a client deadline:
        // cmux-tui does not replay a `new-row` sent again (a second ask is refused `pane_id_exists`), so it is sent once
        // (P0 2026-10-30, R5), as `new-tab` is.
        return DaemonConnection.created(try await connection.requestAwaitingStart(NewRowRequest(pane: pane, height: height, options: options)),
                                        options: options)
    }

    /// Moves tab `surface` into a new row below `pane`'s row, `height` permille tall. The daemon has
    /// no move-tab-to-row: the row opens with a terminal, the tab moves in, that terminal closes.
    public func moveTab(_ surface: SurfaceID, toNewRowBelow pane: PaneID, height: Int) async throws {
        let created = try await newRow(below: pane, height: height)
        let panes = try await connection.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
        guard let row = panes.first(where: { $0.tabs.contains { $0.surface == created.surface } })?.id else {
            throw DaemonError.malformedResponse("pane for surface \(created.surface) not found")
        }
        _ = try await connection.moveTab(surface, to: row, index: 0)
        if let terminal = created.terminalID {
            try await connection.closeTerminal(terminal, incarnation: created.terminalIncarnation)
        } else {
            try await connection.closeTab(created.surface)
        }
    }

    /// Every row height of `column` (`set-row-heights`).
    public func setRowHeights(column: ColumnID, heights: [RowHeightValue], fit: Bool, transaction: UInt64? = nil) async throws {
        try await requireRows()
        _ = try await connection.request(SetRowHeightsRequest(column: column, heights: heights, fit: fit, transaction: transaction))
    }

    private func requireRows() async throws {
        guard await connection.identity?.supports(DaemonCapability.rows.rawValue) == true else {
            throw DaemonError.missingCapabilities([DaemonCapability.rows.rawValue])
        }
    }
}

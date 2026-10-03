import Foundation

/// `move-tab-to-column` with `respawn` (`tab-column-respawn-v1`): a pane's
/// only tab moves into a new column (pinned when `column.sticky` is set) and
/// a fresh tab of the same kind stays in the pane it left. Dock Column on a
/// screen with one tab uses it. It can launch a terminal host, so it uses
/// the spawn deadline.
public struct MoveTabToColumnRespawnRequest: TerminalSpawningRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-column"
    public var column: MoveTabToColumnRequest
    public var respawn: SplitRespawn

    public init(_ column: MoveTabToColumnRequest, respawn: SplitRespawn) {
        self.column = column
        self.respawn = respawn
    }

    private enum CodingKeys: String, CodingKey { case respawn }
    public func encode(to encoder: any Encoder) throws {
        try column.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(respawn, forKey: .respawn)
    }

    /// Sends this request on `connection`. A fresh terminal gets its own
    /// host id and placement environment, as from `new-tab`.
    @discardableResult
    public func send(on connection: DaemonConnection) async throws -> TabMoveResult {
        var request = self
        if case .terminal(let options) = respawn { request.respawn = .terminal(await connection.placed(options)) }
        return try await connection.request(request)
    }
}

import Foundation

/// Drop on a pane edge: new pane beside `pane` on `edge`, holding the tab.
public struct MoveTabToSplitRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-split"
    public var surface: SurfaceID
    public var pane: PaneID
    public var edge: PaneEdge
    /// The new pane's share, 0.05...0.95; nil = 0.5.
    public var ratio: Double?
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil, transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.edge = edge
        self.ratio = ratio
        self.transaction = transaction
    }
}

/// The new tab a split spawns in the source pane when the dragged tab was
/// its only one (`tab-split-respawn-v1`): the same kind, fresh (a new
/// terminal in the dragged terminal's directory, or a new tab page), never
/// a copy of the dragged tab's state.
public enum SplitRespawn: Sendable, Hashable, Encodable {
    case terminal(cwd: String?)
    case browser

    private enum CodingKeys: String, CodingKey { case kind, cwd }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let cwd):
            try container.encode("terminal", forKey: .kind)
            try container.encodeIfPresent(cwd, forKey: .cwd)
        case .browser:
            try container.encode("browser", forKey: .kind)
        }
    }
}

/// `move-tab-to-split` with `respawn`: one owner op that moves the tab into
/// a new pane beside its own pane and spawns `respawn` in the pane it left.
/// It can launch a terminal host, so it uses the spawn deadline.
public struct MoveTabToSplitRespawnRequest: TerminalSpawningRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-split"
    public var surface: SurfaceID
    public var pane: PaneID
    public var edge: PaneEdge
    public var ratio: Double?
    public var respawn: SplitRespawn
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil, respawn: SplitRespawn,
                transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.edge = edge
        self.ratio = ratio
        self.respawn = respawn
        self.transaction = transaction
    }
}

/// Destination screen of a column drop: named directly or by any of its panes.
public enum ColumnDropTarget: Sendable, Hashable {
    case screen(ScreenID)
    case pane(PaneID)
}

/// Drop between strip columns: new viewport column holding the tab.
public struct MoveTabToColumnRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-column"
    public var surface: SurfaceID
    public var target: ColumnDropTarget
    /// Insert after this column; nil = after the last one.
    public var afterColumn: ColumnID?
    /// Viewport fraction 0.1...1.0; nil = 2/3.
    public var width: Double?
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, target: ColumnDropTarget, afterColumn: ColumnID? = nil, width: Double? = nil,
                transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.target = target
        self.afterColumn = afterColumn
        self.width = width
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey { case surface, pane, screen, afterColumn, width, transaction }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        switch target {
        case .screen(let screen): try c.encode(screen, forKey: .screen)
        case .pane(let pane): try c.encode(pane, forKey: .pane)
        }
        try c.encodeIfPresent(afterColumn, forKey: .afterColumn)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}

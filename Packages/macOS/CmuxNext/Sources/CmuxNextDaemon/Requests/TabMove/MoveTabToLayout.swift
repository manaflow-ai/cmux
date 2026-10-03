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
    /// Pins the new column to an edge in the same commit (edge-docks-v1).
    public var sticky: StickySnapshot?
    public var transaction: ClientTransactionID?
    public init(surface: SurfaceID, target: ColumnDropTarget, afterColumn: ColumnID? = nil, width: Double? = nil,
                sticky: StickySnapshot? = nil, transaction: ClientTransactionID? = nil) {
        self.surface = surface
        self.target = target
        self.afterColumn = afterColumn
        self.width = width
        self.sticky = sticky
        self.transaction = transaction
    }

    enum CodingKeys: String, CodingKey { case surface, pane, screen, afterColumn, width, sticky, transaction }
    enum PinKeys: String, CodingKey { case edge, mode }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        switch target {
        case .screen(let screen): try c.encode(screen, forKey: .screen)
        case .pane(let pane): try c.encode(pane, forKey: .pane)
        }
        try c.encodeIfPresent(afterColumn, forKey: .afterColumn)
        try c.encodeIfPresent(width, forKey: .width)
        if let sticky {
            var pin = c.nestedContainer(keyedBy: PinKeys.self, forKey: .sticky)
            try pin.encode(sticky.edge.rawValue, forKey: .edge)
            try pin.encode(sticky.mode.rawValue, forKey: .mode)
        }
        try c.encodeIfPresent(transaction, forKey: .transaction)
    }
}

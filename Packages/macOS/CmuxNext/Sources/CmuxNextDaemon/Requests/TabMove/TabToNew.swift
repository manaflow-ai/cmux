import Foundation

/// Drop on a pane edge: split that pane and move the tab into the new half.
public struct TabToNewSplitRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "tab-to-new-split"
    public var surface: SurfaceID
    public var pane: PaneID
    public var edge: PaneEdge
    /// Share of the new pane, 0.05...0.95; nil = half.
    public var ratio: Double?
    public var clientTransactionID: ClientTransactionID?
    public init(surface: SurfaceID, pane: PaneID, edge: PaneEdge, ratio: Double? = nil, clientTransactionID: ClientTransactionID? = nil) {
        self.surface = surface
        self.pane = pane
        self.edge = edge
        self.ratio = ratio
        self.clientTransactionID = clientTransactionID
    }
}

/// Drop between niri columns or past the last one.
public struct TabToNewColumnRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "tab-to-new-column"
    public var surface: SurfaceID
    public var screen: ScreenID
    /// Insert after this column; nil inserts first.
    public var afterColumn: ColumnID?
    /// Viewport fraction 0.1...1.0; nil = daemon default.
    public var width: Double?
    public var clientTransactionID: ClientTransactionID?
    public init(surface: SurfaceID, screen: ScreenID, afterColumn: ColumnID?, width: Double? = nil, clientTransactionID: ClientTransactionID? = nil) {
        self.surface = surface
        self.screen = screen
        self.afterColumn = afterColumn
        self.width = width
        self.clientTransactionID = clientTransactionID
    }
}

/// Drop on a sidebar gap or the "new" zone, or tear-off into a new window.
public struct TabToNewWorkspaceRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "tab-to-new-workspace"
    public var surface: SurfaceID
    public var name: String?
    public var key: WorkspaceKey?
    public var group: WorkspaceGroupID?
    /// Root (or in-group) index; nil appends.
    public var index: Int?
    public var clientTransactionID: ClientTransactionID?
    public init(surface: SurfaceID, name: String? = nil, key: WorkspaceKey? = nil, group: WorkspaceGroupID? = nil,
                index: Int? = nil, clientTransactionID: ClientTransactionID? = nil) {
        self.surface = surface
        self.name = name
        self.key = key
        self.group = group
        self.index = index
        self.clientTransactionID = clientTransactionID
    }
}

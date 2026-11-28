import Foundation

/// `move-tab-to-split` with `keep_focus` (`tab-split-keep-focus-v1`): the new
/// pane does not take focus. Refused before sending to a daemon without the
/// capability, which would ignore the field and focus the new pane.
public struct MoveTabToSplitKeepingFocusRequest: DaemonRequest {
    public typealias Response = TabMoveResult
    public static let command = "move-tab-to-split"
    public static let requiredCapability: String? = DaemonCapability.tabSplitKeepFocus.rawValue
    public var surface: SurfaceID
    public var pane: PaneID
    public var edge: PaneEdge
    public var ratio: Double?
    public var keepFocus = true
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

/// The dock pin of ``DockSnapshot``: its edge, mode, role and pinned flag (`allowsTabs` is a
/// column setting, not part of the drop).
extension MoveTabToColumnRequest.Dock {
    public init(_ dock: DockSnapshot) {
        self.init(edge: dock.edge, mode: dock.mode, role: dock.role, pinned: dock.isPinned)
    }
}

extension DockSnapshot {
    /// The column a dock drop makes: the drop's pin, without tabs beside it.
    public init(_ dock: MoveTabToColumnRequest.Dock) {
        self.init(edge: dock.edge, mode: dock.mode, role: dock.role, isPinned: dock.pinned)
    }
}

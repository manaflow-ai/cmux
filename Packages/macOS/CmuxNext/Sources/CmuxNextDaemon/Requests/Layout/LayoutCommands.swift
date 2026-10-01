import Foundation

/// Divider drag. Reuse one `transaction` per gesture so undo coalesces.
public struct SetSplitRatioRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-split-ratio"
    public var split: SplitID
    /// Clamped by the daemon to 0.05...0.95.
    public var ratio: Double
    public var transaction: UInt64?
    public init(split: SplitID, ratio: Double, transaction: UInt64? = nil) {
        self.split = split
        self.ratio = ratio
        self.transaction = transaction
    }
}

/// Column width drag (`viewport-column-resize-v1`).
public struct SetColumnWidthRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-viewport-pane-width"
    public var pane: PaneID
    /// 0.1...1.0 of the viewport.
    public var width: Double
    public var transaction: UInt64?
    public init(pane: PaneID, width: Double, transaction: UInt64? = nil) {
        self.pane = pane
        self.width = width
        self.transaction = transaction
    }
}

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

public struct UndoLayoutRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var undone: Bool
        public var screen: ScreenID
        public var revision: UInt64
        public var confirmationRequired: Bool?
        public var closesPanes: [PaneID]?
        enum CodingKeys: String, CodingKey {
            case undone, screen, revision
            case confirmationRequired = "confirmation_required"
            case closesPanes = "closes_panes"
        }
    }
    public static let command = "undo-layout"
    public var pane: PaneID
    public var revision: UInt64?
    public var confirmClose: Bool?
    public init(pane: PaneID, revision: UInt64? = nil, confirmClose: Bool? = nil) {
        self.pane = pane
        self.revision = revision
        self.confirmClose = confirmClose
    }
}

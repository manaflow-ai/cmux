import Foundation

public struct ZoomPaneRequest: DaemonRequest {
    public enum Mode: String, Sendable, Codable { case toggle, on, off }
    public struct Response: Decodable, Sendable, Equatable {
        public var pane: PaneID
        public var zoomed: Bool
        public var zoomedPane: PaneID?
        enum CodingKeys: String, CodingKey {
            case pane, zoomed
            case zoomedPane = "zoomed_pane"
        }
    }
    public static let command = "zoom-pane"
    public var pane: PaneID?
    public var mode: Mode?
    public init(pane: PaneID?, mode: Mode? = nil) {
        self.pane = pane
        self.mode = mode
    }
}

/// TODO(feat-cmux-next-daemon): proposed `move-pane {pane, target, position}`
/// for moving panes and columns. Wire shape is a guess.
public struct MovePaneRequest: DaemonRequest {
    public enum Position: String, Sendable, Codable { case left, right, above, below, columnBefore = "column-before", columnAfter = "column-after" }
    public typealias Response = EmptyResponse
    public static let command = "move-pane"
    public var pane: PaneID
    public var target: PaneID
    public var position: Position
    public init(pane: PaneID, target: PaneID, position: Position) {
        self.pane = pane
        self.target = target
        self.position = position
    }
}

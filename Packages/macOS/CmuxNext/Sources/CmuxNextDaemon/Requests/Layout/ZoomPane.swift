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
    public static let commandName: DaemonCommandName = "zoom-pane"
    public var pane: PaneID?
    public var mode: Mode?
    public init(pane: PaneID?, mode: Mode? = nil) {
        self.pane = pane
        self.mode = mode
    }
}

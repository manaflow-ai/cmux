import Foundation

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

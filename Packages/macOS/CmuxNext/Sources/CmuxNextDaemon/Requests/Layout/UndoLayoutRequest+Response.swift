import Foundation

extension UndoLayoutRequest {
    /// The `undo-layout` reply, both of the schema's shapes in one: an applied undo, or (with
    /// `confirmationRequired`) one that would close `closesPanes` and waits for a confirmation of `revision`.
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
}

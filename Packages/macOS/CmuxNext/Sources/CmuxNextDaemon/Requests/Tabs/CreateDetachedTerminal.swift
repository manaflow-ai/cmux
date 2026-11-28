import Foundation

/// `create-terminal {detached: true}` (generated, swift_app bindings.json): what the daemon answers.
extension CreateDetachedTerminalRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var terminalID: TerminalID
        public var terminalIncarnation: TerminalIncarnation?
        public var terminalResourceID: ResourceID?
        public var lifecycle: String?
        enum CodingKeys: String, CodingKey {
            case lifecycle
            case terminalID = "terminal_id"
            case terminalIncarnation = "terminal_incarnation"
            case terminalResourceID = "terminal_resource_id"
        }
    }
}

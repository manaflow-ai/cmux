import Foundation

/// `close-tabs` result: the closed placements and the terminals that ended.
public struct CloseTabsResult: Decodable, Sendable, Equatable {
    public struct EndedTerminal: Decodable, Sendable, Equatable {
        public var terminalID: TerminalID
        public var terminalIncarnation: TerminalIncarnation?

        enum CodingKeys: String, CodingKey {
            case terminalID = "terminal_id"
            case terminalIncarnation = "terminal_incarnation"
        }
    }

    public var closed: [SurfaceID]
    public var terminals: [EndedTerminal]
    public var resourceRevision: UInt64?
    public var replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case closed, terminals, replayed
        case resourceRevision = "resource_revision"
    }
}

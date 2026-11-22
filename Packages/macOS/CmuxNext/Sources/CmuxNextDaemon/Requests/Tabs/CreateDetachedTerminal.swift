import Foundation

/// `create-terminal {detached: true}` (`remote-terminal-tabs-v1`): a kept
/// terminal with no tab on its own session, whose only view lives in another
/// session's layout ("Open Terminal on Machine Here").
public struct CreateDetachedTerminalRequest: TerminalSpawningRequest {
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
    public static let command = "create-terminal"
    public var cwd: String?
    public var size: CellSize?
    public var terminalID: TerminalID?
    public var env: [String: String]?
    public var mutation: MutationIdentity?

    public init(cwd: String? = nil, size: CellSize? = nil, terminalID: TerminalID? = nil, env: [String: String]? = nil,
                mutation: MutationIdentity?) {
        self.cwd = cwd
        self.size = size
        self.terminalID = terminalID
        self.env = env
        self.mutation = mutation
    }

    enum CodingKeys: String, CodingKey { case detached, keep, cwd, cols, rows, terminalID, env }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(true, forKey: .detached)
        try c.encode(true, forKey: .keep)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(size?.cols, forKey: .cols)
        try c.encodeIfPresent(size?.rows, forKey: .rows)
        try c.encodeIfPresent(terminalID, forKey: .terminalID)
        try c.encodeIfPresent(env, forKey: .env)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

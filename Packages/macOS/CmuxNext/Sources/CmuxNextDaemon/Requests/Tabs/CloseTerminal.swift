import Foundation

/// Kills the PTY at once. Closing a tab/pane/screen only detaches it; with
/// `terminal-reap-v1` the daemon ends it after the reap grace period unless kept.
public struct CloseTerminalRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "close-terminal"
    public var terminalID: TerminalID
    public var terminalIncarnation: TerminalIncarnation?
    public var mutation: MutationIdentity?
    public init(terminalID: TerminalID, terminalIncarnation: TerminalIncarnation? = nil, mutation: MutationIdentity?) {
        self.terminalID = terminalID
        self.terminalIncarnation = terminalIncarnation
        self.mutation = mutation
    }
    enum CodingKeys: String, CodingKey { case terminalID, terminalIncarnation }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(terminalID, forKey: .terminalID)
        try c.encodeIfPresent(terminalIncarnation, forKey: .terminalIncarnation)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

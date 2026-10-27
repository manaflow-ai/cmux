/// Ends one attach stream this side minted (`attach-streams-v1`): the daemon drops what the stream still
/// queues, queues its `stream-end {reason: "canceled"}` and removes the view, all before the reply. An id
/// with no open stream answers `ended` and changes nothing (cmux-tui/spec/commands.md, `cancel-stream`).
public struct CancelStreamRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var stream: UInt16
        /// `applied` (the stream ended now) or `ended` (it had ended already).
        public var outcome: String
    }
    public static let commandName: DaemonCommandName = "cancel-stream"
    public var stream: UInt16

    public init(stream: UInt16) {
        self.stream = stream
    }
}

/// How one terminal view's attach stream competes with the others on its connection
/// (`set-stream-priority`; cmux-tui/spec/commands.md). As Chrome ranks a renderer by its
/// widgets' visibility (`RenderWidgetHostImpl::WasShown`/`WasHidden`): the focused view's output rides the
/// input lane, a visible one the bulk lane, and a hidden snapshot view gets no output until it shows, then
/// one READY if its terminal printed meanwhile.
public enum TerminalStreamPriority: String, Sendable, Codable, Equatable {
    case focused
    case visible
    case hidden

    /// The view's rank from what the person sees: hidden unless it shows, focused when it also has focus.
    public init(visible: Bool, focused: Bool) {
        self = visible ? (focused ? .focused : .visible) : .hidden
    }
}

/// Sets the priority of one attach stream this side minted (`attach-streams-v1`). An id with no open stream
/// answers `ended` and changes nothing.
public struct SetStreamPriorityRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var stream: UInt16
        /// `applied`, or `ended` (no open stream with that id).
        public var outcome: String
    }
    public static let commandName: DaemonCommandName = "set-stream-priority"
    public static var requiredCapability: String? { "attach-streams-v1" }
    public var stream: UInt16
    public var priority: TerminalStreamPriority

    public init(stream: UInt16, priority: TerminalStreamPriority) {
        self.stream = stream
        self.priority = priority
    }
}

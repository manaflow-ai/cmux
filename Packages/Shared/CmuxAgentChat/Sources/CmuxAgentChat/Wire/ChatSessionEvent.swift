/// A live update to one session's conversation, pushed by the host.
public enum ChatSessionEvent: Sendable, Equatable {
    /// New messages were appended to the transcript tail.
    case appended([ChatMessage])
    /// Previously-delivered messages changed in place (a tool result
    /// arrived, a permission request was resolved). Receivers replace by
    /// ``ChatMessage/id``.
    case updated([ChatMessage])
    /// The session's live activity state changed.
    case stateChanged(ChatAgentState)
    /// The session's descriptor changed (title, terminal binding, ...).
    case descriptorChanged(ChatSessionDescriptor)
    /// The producing host removed this session from its live registry.
    case sessionRemoved

    /// Terminal command-blocks were appended or updated (terminal-kind
    /// sessions). Receivers upsert by ``TerminalCommandBlock/id``; the
    /// producer sends the whole current block value, so a replayed block on
    /// reconnect is idempotent.
    case terminalBlocks([TerminalCommandBlock])

    /// A live, not-yet-committed preview of the agent's in-progress prose for
    /// the current turn, scraped from the terminal's rendered screen while the
    /// authoritative JSONL line has not been written yet. The payload replaces
    /// any prior preview wholesale; `nil` clears it. It lives outside the
    /// message window and is superseded the instant the authoritative agent
    /// prose lands via ``appended``, so it never duplicates a real message.
    case streamingProse(ChatMessage?)

    /// The producing transcript was truncated or replaced; the session's
    /// seq space restarted and clients must re-anchor from history.
    case reset

    /// An event name this client predates; carried (not dropped) so
    /// consumers can ignore it explicitly.
    case unknown(String)
}

extension ChatSessionEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event
        case messages
        case message
        case state
        case descriptor
        case blocks
    }

    private enum EventName: String {
        case appended
        case updated
        case stateChanged = "state_changed"
        case descriptorChanged = "descriptor_changed"
        case sessionRemoved = "session_removed"
        case terminalBlocks = "terminal_blocks"
        case streamingProse = "streaming_prose"
        case reset
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .event)
        switch EventName(rawValue: raw) {
        case .appended:
            self = .appended(try container.decode([ChatMessage].self, forKey: .messages))
        case .updated:
            self = .updated(try container.decode([ChatMessage].self, forKey: .messages))
        case .stateChanged:
            self = .stateChanged(try container.decode(ChatAgentState.self, forKey: .state))
        case .descriptorChanged:
            self = .descriptorChanged(try container.decode(ChatSessionDescriptor.self, forKey: .descriptor))
        case .sessionRemoved:
            self = .sessionRemoved
        case .terminalBlocks:
            self = .terminalBlocks(try container.decode([TerminalCommandBlock].self, forKey: .blocks))
        case .streamingProse:
            self = .streamingProse(try container.decodeIfPresent(ChatMessage.self, forKey: .message))
        case .reset:
            self = .reset
        case .none:
            // A newer Mac may push event names this client predates; an
            // explicit ignorable case beats silently dropping the frame at
            // the transport layer.
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appended(let messages):
            try container.encode(EventName.appended.rawValue, forKey: .event)
            try container.encode(messages, forKey: .messages)
        case .updated(let messages):
            try container.encode(EventName.updated.rawValue, forKey: .event)
            try container.encode(messages, forKey: .messages)
        case .stateChanged(let state):
            try container.encode(EventName.stateChanged.rawValue, forKey: .event)
            try container.encode(state, forKey: .state)
        case .descriptorChanged(let descriptor):
            try container.encode(EventName.descriptorChanged.rawValue, forKey: .event)
            try container.encode(descriptor, forKey: .descriptor)
        case .sessionRemoved:
            try container.encode(EventName.sessionRemoved.rawValue, forKey: .event)
        case .terminalBlocks(let blocks):
            try container.encode(EventName.terminalBlocks.rawValue, forKey: .event)
            try container.encode(blocks, forKey: .blocks)
        case .streamingProse(let message):
            try container.encode(EventName.streamingProse.rawValue, forKey: .event)
            try container.encodeIfPresent(message, forKey: .message)
        case .reset:
            try container.encode(EventName.reset.rawValue, forKey: .event)
        case .unknown(let raw):
            try container.encode(raw, forKey: .event)
        }
    }
}

public import CmuxAgentReplica

/// The `gui.v1` event payload carried inside the existing transport event envelope.
public struct GuiEventFrame: Codable, Hashable, Sendable {
    /// The Mac process epoch that scopes the event.
    public let epoch: ReplicaEpoch
    /// The session scoped by the event, when applicable.
    public let sessionID: AgentSessionID?
    /// The payload decoded according to the open event kind.
    public let payload: GuiEventPayload
    /// The open event-kind string.
    public var kind: String { payload.kind }

    private enum CodingKeys: String, CodingKey {
        case epoch
        case sessionID = "session_id"
        case kind
        case payload
    }

    private enum EmptyCodingKeys: CodingKey {}

    /// Creates an event frame payload.
    /// - Parameters:
    ///   - epoch: The Mac process epoch.
    ///   - sessionID: The scoped session identifier, when applicable.
    ///   - payload: The typed or unknown event payload.
    public init(epoch: ReplicaEpoch, sessionID: AgentSessionID? = nil, payload: GuiEventPayload) {
        self.epoch = epoch
        self.sessionID = sessionID
        self.payload = payload
    }

    /// Decodes a frame, mapping unknown kinds or malformed known payloads to `unknown`.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.epoch = try container.decode(ReplicaEpoch.self, forKey: .epoch)
        self.sessionID = try? container.decodeIfPresent(AgentSessionID.self, forKey: .sessionID)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        switch kind {
        case "session_upserted":
            self.payload = Self.decode(GuiSessionUpsertedEvent.self, from: container).map(GuiEventPayload.sessionUpserted) ?? .unknown(kind)
        case "session_removed":
            self.payload = Self.decode(GuiSessionRemovedEvent.self, from: container).map(GuiEventPayload.sessionRemoved) ?? .unknown(kind)
        case "entries_appended":
            self.payload = Self.decode(GuiEntriesAppendedEvent.self, from: container).map(GuiEventPayload.entriesAppended) ?? .unknown(kind)
        case "entry_replaced":
            self.payload = Self.decode(GuiEntryReplacedEvent.self, from: container).map(GuiEventPayload.entryReplaced) ?? .unknown(kind)
        case "journal_reset":
            self.payload = Self.decode(GuiJournalResetEvent.self, from: container).map(GuiEventPayload.journalReset) ?? .unknown(kind)
        case "send_state":
            self.payload = Self.decode(GuiSendStateEvent.self, from: container).map(GuiEventPayload.sendState) ?? .unknown(kind)
        case "ask_state":
            self.payload = Self.decode(GuiAskStateEvent.self, from: container).map(GuiEventPayload.askState) ?? .unknown(kind)
        case "stream_tick":
            self.payload = Self.decode(GuiStreamTickEvent.self, from: container).map(GuiEventPayload.streamTick) ?? .unknown(kind)
        default:
            self.payload = .unknown(kind)
        }
    }

    /// Encodes a typed frame using its stable snake_case event kind.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encode(kind, forKey: .kind)
        switch payload {
        case .sessionUpserted(let value): try container.encode(value, forKey: .payload)
        case .sessionRemoved(let value): try container.encode(value, forKey: .payload)
        case .entriesAppended(let value): try container.encode(value, forKey: .payload)
        case .entryReplaced(let value): try container.encode(value, forKey: .payload)
        case .journalReset(let value): try container.encode(value, forKey: .payload)
        case .sendState(let value): try container.encode(value, forKey: .payload)
        case .askState(let value): try container.encode(value, forKey: .payload)
        case .streamTick(let value): try container.encode(value, forKey: .payload)
        case .unknown:
            _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: .payload)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Value? {
        try? container.decode(type, forKey: .payload)
    }
}

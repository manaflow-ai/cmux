public import CmuxAgentReplica

/// Value input consumed by ``TranscriptProjector``.
public struct TranscriptProjectionInput: Sendable {
    /// Loaded entries in ascending journal sequence order.
    public let entries: [EntrySnapshot]
    /// Known holes in the local entry window.
    public let holes: [EntryRange]
    /// Whether older history exists on the Mac before the retained window.
    public let hasMoreBefore: Bool
    /// FIFO local send tickets.
    public let sendTickets: [SendTicket]
    /// Pending asks in stable order.
    public let asks: [PendingAsk]
    /// The optional streaming tail preview.
    public let streamingTail: TranscriptStreamingTail?
    /// Current session phase used to keep live activity unfolded.
    public let sessionPhase: SessionPhase
    /// The read pointer sequence.
    public let unreadPointer: EntrySeq
    /// Maps an entry to a deterministic display tick.
    public let displayTick: @Sendable (EntrySnapshot) -> Int
    /// Maps a display tick to a display day key.
    public let dayKey: @Sendable (Int) -> String

    /// Creates projection input.
    /// - Parameters:
    ///   - entries: Loaded entries in ascending journal sequence order.
    ///   - holes: Known holes in the local entry window.
    ///   - hasMoreBefore: Whether older history exists before the retained window.
    ///   - sendTickets: FIFO local send tickets.
    ///   - asks: Pending asks in stable order.
    ///   - streamingTail: Optional streaming tail preview.
    ///   - sessionPhase: Current phase used to keep live activity unfolded.
    ///   - unreadPointer: Read pointer sequence.
    ///   - displayTick: Deterministic display tick provider.
    ///   - dayKey: Display day key provider for a tick.
    public init(
        entries: [EntrySnapshot],
        holes: [EntryRange] = [],
        hasMoreBefore: Bool = false,
        sendTickets: [SendTicket] = [],
        asks: [PendingAsk] = [],
        streamingTail: TranscriptStreamingTail? = nil,
        sessionPhase: SessionPhase = .idle,
        unreadPointer: EntrySeq = EntrySeq(rawValue: 0),
        displayTick: @escaping @Sendable (EntrySnapshot) -> Int = { $0.seq.rawValue },
        dayKey: @escaping @Sendable (Int) -> String = { "day-\($0 / 86_400)" }
    ) {
        self.entries = entries.sorted { $0.seq < $1.seq }
        self.holes = holes.sorted { $0.lowerBound < $1.lowerBound }
        self.hasMoreBefore = hasMoreBefore
        self.sendTickets = sendTickets
        self.asks = asks
        self.streamingTail = streamingTail
        self.sessionPhase = sessionPhase
        self.unreadPointer = unreadPointer
        self.displayTick = displayTick
        self.dayKey = dayKey
    }

    /// Creates projection input from a conversation replica snapshot.
    /// - Parameters:
    ///   - state: The replica state snapshot.
    ///   - hasMoreBefore: Whether older history exists before the retained window.
    ///   - streamingTail: Optional streaming tail preview.
    ///   - sessionPhase: Current phase used to keep live activity unfolded.
    ///   - displayTick: Deterministic display tick provider.
    ///   - dayKey: Display day key provider for a tick.
    public init(
        state: ConversationReplicaState,
        hasMoreBefore: Bool,
        streamingTail: TranscriptStreamingTail? = nil,
        sessionPhase: SessionPhase = .idle,
        displayTick: @escaping @Sendable (EntrySnapshot) -> Int = { $0.seq.rawValue },
        dayKey: @escaping @Sendable (Int) -> String = { "day-\($0 / 86_400)" }
    ) {
        self.init(
            entries: state.entries,
            holes: state.holes,
            hasMoreBefore: hasMoreBefore,
            sendTickets: state.sendTickets,
            asks: state.asks,
            streamingTail: streamingTail,
            sessionPhase: sessionPhase,
            unreadPointer: state.readPointer,
            displayTick: displayTick,
            dayKey: dayKey
        )
    }
}

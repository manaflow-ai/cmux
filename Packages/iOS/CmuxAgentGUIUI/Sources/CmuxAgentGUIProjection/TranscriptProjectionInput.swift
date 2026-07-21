public import CmuxAgentReplica

/// Value input consumed by ``TranscriptProjector``.
public struct TranscriptProjectionInput: Sendable {
    /// Whether the replica has received its first authoritative journal page.
    public let hasCompletedInitialSync: Bool
    /// Loaded entries in ascending journal sequence order.
    public let entries: [EntrySnapshot]
    /// Known holes in the local entry window.
    public let holes: [EntryRange]
    /// Whether older history exists on the Mac before the retained window.
    public let hasMoreBefore: Bool
    /// Whether newer history exists on the Mac after the retained window.
    public let hasMoreAfter: Bool
    /// Opaque boundary for the next older page request.
    public let startCursor: JournalCursor?
    /// Opaque boundary for the next newer page request.
    public let endCursor: JournalCursor?
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
    public let dayKey: @Sendable (Int) -> String?

    /// Whether the projector has any durable or transient row content to display.
    public var hasVisibleContent: Bool {
        entries.contains { !$0.content.payload.isTranscriptInternal }
            || hasMoreBefore
            || !holes.isEmpty
            || sendTickets.contains { ticket in
                if case .echoed = ticket.state { return false }
                return true
            }
            || asks.contains { $0.state == .active }
            || streamingTail?.textTail.isEmpty == false
    }

    /// Creates projection input.
    /// - Parameters:
    ///   - hasCompletedInitialSync: Whether the first authoritative journal page arrived.
    ///   - entries: Loaded entries in ascending journal sequence order.
    ///   - holes: Known holes in the local entry window.
    ///   - hasMoreBefore: Whether older history exists before the retained window.
    ///   - hasMoreAfter: Whether newer history exists after the retained window.
    ///   - startCursor: Opaque oldest loaded page boundary.
    ///   - endCursor: Opaque newest loaded page boundary.
    ///   - sendTickets: FIFO local send tickets.
    ///   - asks: Pending asks in stable order.
    ///   - streamingTail: Optional streaming tail preview.
    ///   - sessionPhase: Current phase used to keep live activity unfolded.
    ///   - unreadPointer: Read pointer sequence.
    ///   - displayTick: Deterministic display tick provider.
    ///   - dayKey: Display day key provider for a tick.
    public init(
        hasCompletedInitialSync: Bool = false,
        entries: [EntrySnapshot],
        holes: [EntryRange] = [],
        hasMoreBefore: Bool = false,
        hasMoreAfter: Bool = false,
        startCursor: JournalCursor? = nil,
        endCursor: JournalCursor? = nil,
        sendTickets: [SendTicket] = [],
        asks: [PendingAsk] = [],
        streamingTail: TranscriptStreamingTail? = nil,
        sessionPhase: SessionPhase = .idle,
        unreadPointer: EntrySeq = EntrySeq(rawValue: 0),
        displayTick: @escaping @Sendable (EntrySnapshot) -> Int = { $0.seq.rawValue },
        dayKey: @escaping @Sendable (Int) -> String? = { _ in nil }
    ) {
        self.hasCompletedInitialSync = hasCompletedInitialSync
        self.entries = entries.sorted { $0.seq < $1.seq }
        self.holes = holes.sorted { $0.lowerBound < $1.lowerBound }
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.startCursor = startCursor
        self.endCursor = endCursor
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
    ///   - hasMoreAfter: Whether newer history exists after the retained window.
    ///   - startCursor: Opaque oldest loaded page boundary.
    ///   - endCursor: Opaque newest loaded page boundary.
    ///   - streamingTail: Optional streaming tail preview.
    ///   - sessionPhase: Current phase used to keep live activity unfolded.
    ///   - displayTick: Deterministic display tick provider.
    ///   - dayKey: Display day key provider for a tick.
    public init(
        state: ConversationReplicaState,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool = false,
        startCursor: JournalCursor? = nil,
        endCursor: JournalCursor? = nil,
        streamingTail: TranscriptStreamingTail? = nil,
        sessionPhase: SessionPhase = .idle,
        displayTick: @escaping @Sendable (EntrySnapshot) -> Int = { $0.seq.rawValue },
        dayKey: @escaping @Sendable (Int) -> String? = { _ in nil }
    ) {
        self.init(
            hasCompletedInitialSync: state.journalID != nil,
            entries: state.entries,
            holes: state.holes,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            startCursor: startCursor,
            endCursor: endCursor,
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

extension EntryPayload {
    var isTranscriptInternal: Bool {
        guard case .status(let status) = self else { return false }
        switch status.code {
        case .sessionMeta:
            return true
        case .other(let rawCode):
            return rawCode == "stop_hook_summary"
        case .compacted, .turnAborted, .apiError:
            return false
        }
    }
}

// One row of the method tables (MethodTable.swift).

/// What the transport knows about a command or v2 operation.
public struct MethodAttributes: Hashable, Sendable {
    public let id: MethodID
    /// The wire name (`cmd` of a v12 line, `operation` of a v2 envelope).
    public let name: String
    public let priority: MethodPriority
    public let ordering: MethodOrdering
    public let durability: MethodDurability
    public let payload: MethodPayload
    /// Addressed to one stream; runs on that stream's sequence.
    public let streamScoped: Bool
    /// Why this control command may pass input queued on a stream of its
    /// target; nil means it waits for that stream to drain.
    public let crossesStreamOK: String?
    /// Largest request payload; nil is the frame cap.
    public let maxBytes: UInt32?
    public let coalesce: MethodCoalesce?
    /// May ask the receiving scheduler to run it first (Mojo `[SupportsUrgent]`).
    public let urgent: Bool

    public init(
        id: MethodID,
        name: String,
        priority: MethodPriority,
        ordering: MethodOrdering,
        durability: MethodDurability,
        payload: MethodPayload,
        streamScoped: Bool,
        crossesStreamOK: String?,
        maxBytes: UInt32?,
        coalesce: MethodCoalesce?,
        urgent: Bool
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.ordering = ordering
        self.durability = durability
        self.payload = payload
        self.streamScoped = streamScoped
        self.crossesStreamOK = crossesStreamOK
        self.maxBytes = maxBytes
        self.coalesce = coalesce
        self.urgent = urgent
    }
}

/// What the transport knows about an event.
public struct EventAttributes: Hashable, Sendable {
    public let id: EventID
    public let name: String
    public let priority: MethodPriority
    public let coalesce: MethodCoalesce?

    public init(id: EventID, name: String, priority: MethodPriority, coalesce: MethodCoalesce?) {
        self.id = id
        self.name = name
        self.priority = priority
        self.coalesce = coalesce
    }
}

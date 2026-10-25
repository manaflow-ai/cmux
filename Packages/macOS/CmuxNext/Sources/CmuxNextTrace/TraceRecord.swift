/// One decoded trace ring record and the thread that wrote it (``TraceRing``).
public struct TraceRecord: Sendable, Equatable {
    /// `CLOCK_UPTIME_RAW` nanoseconds.
    public var timestamp: UInt64
    /// The catalog name id.
    public var name: UInt16
    /// The raw phase byte; ``phase`` reads it.
    public var phaseCode: UInt8
    /// Bit 0: `arg1` is an async or track id; bit 1: the time is estimated.
    public var flags: UInt8
    /// The first argument.
    public var arg0: UInt64
    /// The second argument.
    public var arg1: UInt64
    /// The writer's index in the thread table.
    public var threadIndex: UInt32
    /// The generation of that thread-table entry.
    public var threadGeneration: UInt32
    /// The chunk's claim ticket (lap * chunk count + chunk index): a thread's later chunks have larger tickets.
    public var ticket: UInt64
    /// The record's slot in its chunk (1-31).
    public var slot: Int

    /// The phase, or nil for a code this build does not know.
    public var phase: Phase? { Phase(rawValue: phaseCode) }

    /// What a record marks.
    public enum Phase: UInt8, Sendable, CaseIterable {
        case begin = 1
        case end = 2
        case instant = 3
        case asyncBegin = 4
        case asyncEnd = 5
        case flowOut = 6
        case flowIn = 7
        case counter = 8
    }
}

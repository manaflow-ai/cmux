/// One decoded trace ring record and the thread that wrote it (``TraceRing``).
public struct TraceRecord: Sendable, Equatable {
    /// Trace clock nanoseconds (`CLOCK_UPTIME_RAW` on macOS).
    public var timestamp: UInt64
    /// The name id in the ring's name table.
    public var name: UInt16
    /// The raw phase byte; ``phase`` reads it.
    public var phaseCode: UInt8
    /// Bit 0: `arg1` is an async or track id; bit 1: the time is an estimate.
    public var flags: UInt8
    /// The first argument.
    public var arg0: UInt64
    /// The second argument.
    public var arg1: UInt64
    /// The writer's entry in the ring's thread table, or `0xFFFFFFFF` when the table was full.
    public var threadIndex: UInt32
    /// The generation of that thread-table entry when the writer claimed the chunk.
    public var threadGeneration: UInt32
    /// The chunk's claim ticket (lap * chunk count + chunk index): a thread's later chunks have larger tickets.
    public var ticket: UInt64
    /// The record's slot in its chunk (1-31).
    public var slot: Int

    /// The phase, or nil for a code this build does not know.
    public var phase: Phase? { Phase(rawValue: phaseCode) }

    /// What a record marks: the ASCII codes of Chrome's JSON trace (`TRACE_EVENT_PHASE_*` in
    /// `base/trace_event/common/trace_event_common.h`), as plans/cmux-next/trace.md "Record" lists them.
    /// Code 0 is invalid.
    public enum Phase: UInt8, Sendable, CaseIterable {
        /// `B`: a slice begins on the writing thread.
        case begin = 0x42
        /// `E`: the slice with the same name ends on the same thread.
        case end = 0x45
        /// `I`: an instant.
        case instant = 0x49
        /// `b`: an async slice begins (`arg1` is its async id, flag bit 0 set).
        case asyncBegin = 0x62
        /// `e`: the async slice with that id ends, on any thread.
        case asyncEnd = 0x65
        /// `s`: a flow leaves this point (`arg1` is the flow id).
        case flowOut = 0x73
        /// `f`: a flow arrives at this point (`arg1` is the flow id).
        case flowIn = 0x66
        /// `C`: a counter sample (`arg0` is the value, `arg1` a track id with flag bit 0).
        case counter = 0x43
    }
}

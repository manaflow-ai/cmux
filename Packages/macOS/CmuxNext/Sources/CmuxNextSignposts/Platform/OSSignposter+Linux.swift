// The `os` signpost types this module uses, where `os` does not exist (Linux; p15-oracle.md section H). On Apple
// platforms the module uses `os.OSSignposter` itself (re-exported by CmuxNextCompat) and this file is empty.
//
// There is no unified log to export to, so every emit is a no-op and its message is never built: the trace ring
// still takes every record (Signposter+TraceRing.swift), as Chromium's trace events still reach the Perfetto
// buffer on a platform with no system exporter (the ETW export exists only on Windows,
// base/trace_event/trace_event_etw_export_win.h). Ids stay unique per process, because the ring keys async
// slices by them.

#if !canImport(os)
public import CmuxNextCompat
internal import CmuxNextSignpostsC

/// A signpost id (`os.OSSignpostID`).
public struct OSSignpostID: Sendable, Hashable {
    /// The id's value.
    public let rawValue: UInt64

    /// The id `value`.
    public init(_ value: UInt64) {
        rawValue = value
    }

    /// `OS_SIGNPOST_ID_NULL`.
    public static let null = OSSignpostID(0)
    /// `OS_SIGNPOST_ID_INVALID`.
    public static let invalid = OSSignpostID(~0)
    /// `OS_SIGNPOST_ID_EXCLUSIVE`: the id of an interval that never overlaps another of its name.
    public static let exclusive = OSSignpostID(0xEEEE_B0B5_B2B2_EEEE)
}

/// What an interval's end needs from its begin (`os.OSSignpostIntervalState`).
public struct OSSignpostIntervalState: Sendable {
    /// The interval's id.
    public let signpostID: OSSignpostID

    /// The state of an interval begun with `id` (an end whose begin returned no state).
    public static func beginState(id: OSSignpostID) -> OSSignpostIntervalState {
        OSSignpostIntervalState(signpostID: id)
    }
}

/// A signposter that records nothing (`os.OSSignposter`): ``isEnabled`` is false, and the messages are
/// autoclosures that are never called.
public struct OSSignposter: Sendable {
    /// A signposter for `category` in `subsystem`.
    public init(subsystem: String, category: String) {}

    /// Always false: nothing takes the signposts.
    public var isEnabled: Bool { false }

    /// A new id, unique in the process (`os_signpost_id_generate`): one counter with the C emitters'.
    public func makeSignpostID() -> OSSignpostID {
        OSSignpostID(cmux_signpost_next_id())
    }

    /// Begins interval `name`.
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState {
        .beginState(id: id)
    }

    /// Begins interval `name` with a message.
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive,
                              _ message: @autoclosure () -> OSLogMessage) -> OSSignpostIntervalState {
        .beginState(id: id)
    }

    /// Ends interval `name`.
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {}

    /// Ends interval `name` with a message.
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState,
                            _ message: @autoclosure () -> OSLogMessage) {}

    /// Emits point event `name`.
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive) {}

    /// Emits point event `name` with a message.
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive,
                          _ message: @autoclosure () -> OSLogMessage) {}
}
#endif

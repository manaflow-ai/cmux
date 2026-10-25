import CmuxNextTrace

/// The typed trace points on the process's runtime (``TraceRuntime/shared``): numbers only, written to the
/// Release trace ring under the name's category flag (Chrome's `TRACE_EVENT*` macros,
/// base/trace_event/trace_event.h). A name's doc comment in ``SignpostName`` says what `arg0` and `arg1` hold.
/// Off, each call costs one relaxed load and one branch; on, one 32-byte record with no lock, allocation or
/// message text.
///
/// These are static: the name carries its category, so a category with no ``Signposter`` handle
/// (frame, task, hang, ...) needs none. Code that holds an injected runtime calls the same points on it
/// (TraceRuntime+SignpostName.swift); tests make their own runtime that way. Unlike the `os_signpost`
/// intervals above, they reach Instruments only through a ring export (`cmux trace record`).
///
/// Stub (task 000): the signatures are frozen and record nothing until task 003 adds the ring.
///
/// ```swift
/// Signposter.event(.frameTick, arg0: tick.timestamp, arg1: tick.targetTimestamp)
/// Signposter.asyncBegin(.createTab, id: intent.id, arg0: kind)
/// ```
extension Signposter {
    /// Begins a same-thread slice (B); end it on this thread with ``end(_:arg0:arg1:)``.
    public static func begin(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0) {
        TraceRuntime.shared.begin(name, arg0: arg0, arg1: arg1)
    }

    /// Ends the innermost slice named `name` on this thread (E), with its result numbers.
    public static func end(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0) {
        TraceRuntime.shared.end(name, arg0: arg0, arg1: arg1)
    }

    /// Runs `body` inside a same-thread slice named `name`.
    ///
    /// - Returns: What `body` returns.
    public static func interval<T>(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0,
                                   _ body: () throws -> T) rethrows -> T {
        try TraceRuntime.shared.interval(name, arg0: arg0, arg1: arg1, body)
    }

    /// Begins an async slice (AB) that may end on another thread or turn, or overlap another of the same
    /// name: `id` (an intent id, a request id, an `OSSignpostID` value) pairs it with ``asyncEnd(_:id:arg0:)``.
    public static func asyncBegin(_ name: SignpostName, id: UInt64, arg0: UInt64 = 0) {
        TraceRuntime.shared.asyncBegin(name, id: id, arg0: arg0)
    }

    /// Ends the async slice named `name` with `id` (AE), with its result number.
    public static func asyncEnd(_ name: SignpostName, id: UInt64, arg0: UInt64 = 0) {
        TraceRuntime.shared.asyncEnd(name, id: id, arg0: arg0)
    }

    /// Records a point event (I). `estimated` marks a time the app computed, not measured
    /// (``SignpostName/framePresentEstimate``).
    public static func event(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0, estimated: Bool = false) {
        TraceRuntime.shared.event(name, arg0: arg0, arg1: arg1, estimated: estimated)
    }

    /// Records that flow `flow` leaves this point (a queue hop's enqueue, a request's send).
    public static func flowOut(_ name: SignpostName, flow: UInt64, arg0: UInt64 = 0) {
        TraceRuntime.shared.flowOut(name, flow: flow, arg0: arg0)
    }

    /// Records that flow `flow` arrives at this point (a queue hop's dequeue, a reply's receive).
    public static func flowIn(_ name: SignpostName, flow: UInt64, arg0: UInt64 = 0) {
        TraceRuntime.shared.flowIn(name, flow: flow, arg0: arg0)
    }

    /// Records a counter's value.
    public static func counter(_ name: SignpostName, value: UInt64) {
        TraceRuntime.shared.counter(name, value: value)
    }
}

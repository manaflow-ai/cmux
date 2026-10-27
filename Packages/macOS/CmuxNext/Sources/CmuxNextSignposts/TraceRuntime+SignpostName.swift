public import CmuxNextTrace

/// The typed trace points on one runtime: the injected form of ``Signposter``'s static points, for code
/// and tests that hold a ``TraceRuntime`` (the record layout is plans/cmux-next/trace.md "Release trace
/// ring v1"). The phase codes, flags and argument slots are the ring's: an async id, flow id or track
/// id goes in `arg1`.
///
/// ```swift
/// runtime.asyncBegin(.daemonRequest, id: requestID, arg0: method)
/// ```
extension TraceRuntime {
    /// Begins a same-thread slice (B); end it on this thread with ``end(_:arg0:arg1:)``.
    ///
    /// - Returns: Whether the begin was written (its category was on).
    @discardableResult
    public func begin(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0) -> Bool {
        record(name, .begin, arg0: arg0, arg1: arg1)
    }

    /// Ends the innermost slice named `name` on this thread (E), with its result numbers.
    public func end(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0) {
        record(name, .end, arg0: arg0, arg1: arg1)
    }

    /// Runs `body` inside a same-thread slice named `name`. The category is read once, at the begin: a
    /// written begin always gets its end.
    ///
    /// - Returns: What `body` returns.
    public func interval<T>(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0, _ body: () throws -> T) rethrows -> T {
        let recorded = record(name, .begin, arg0: arg0, arg1: arg1)
        defer { if recorded { endRecorded(name, arg0: 0) } }
        return try body()
    }

    /// Begins an async slice (AB) keyed by `id`; ``asyncEnd(_:id:arg0:)`` with the same name and id ends it.
    ///
    /// - Returns: Whether the begin was written (its category was on).
    @discardableResult
    public func asyncBegin(_ name: SignpostName, id: UInt64, arg0: UInt64 = 0) -> Bool {
        record(name, .asyncBegin, flags: .asyncID, arg0: arg0, arg1: id)
    }

    /// The E of a B that ``begin(_:arg0:arg1:)`` wrote, whatever the category flags are now.
    func endRecorded(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0) {
        writeEnd(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: .end, arg0: arg0, arg1: arg1)
    }

    /// The AE of an AB that ``asyncBegin(_:id:arg0:)`` wrote, whatever the category flags are now.
    func asyncEndRecorded(_ name: SignpostName, id: UInt64, arg0: UInt64) {
        writeEnd(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: .asyncEnd, flags: .asyncID,
                 arg0: arg0, arg1: id)
    }

    /// Ends the async slice named `name` with `id` (AE), with its result number.
    public func asyncEnd(_ name: SignpostName, id: UInt64, arg0: UInt64 = 0) {
        record(name, .asyncEnd, flags: .asyncID, arg0: arg0, arg1: id)
    }

    /// Records a point event (I); `estimated` marks a computed time, not a measured one.
    public func event(_ name: SignpostName, arg0: UInt64, arg1: UInt64 = 0, estimated: Bool = false) {
        record(name, .instant, flags: estimated ? .estimated : [], arg0: arg0, arg1: arg1)
    }

    /// Records that flow `flow` leaves this point (`s`; the flow id is `arg1`).
    public func flowOut(_ name: SignpostName, flow: UInt64, arg0: UInt64 = 0) {
        record(name, .flowOut, arg0: arg0, arg1: flow)
    }

    /// Records that flow `flow` arrives at this point (`f`; the flow id is `arg1`).
    public func flowIn(_ name: SignpostName, flow: UInt64, arg0: UInt64 = 0) {
        record(name, .flowIn, arg0: arg0, arg1: flow)
    }

    /// Records a counter's value (`C`; the value is `arg0`).
    public func counter(_ name: SignpostName, value: UInt64) {
        record(name, .counter, arg0: value)
    }

    @discardableResult
    private func record(_ name: SignpostName, _ phase: Phase, flags: RecordFlags = [], arg0: UInt64 = 0,
                        arg1: UInt64 = 0) -> Bool {
        write(name: name.rawValue, categoryBit: name.traceCategory.traceBit, phase: phase, flags: flags,
              arg0: arg0, arg1: arg1)
    }
}

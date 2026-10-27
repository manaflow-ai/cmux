import CmuxNextSignposts
import CmuxNextTrace
import CmuxNextWakeups

/// One queued control request's `control.request` async slice (AB/AE keyed by an id minted per request), from the
/// enqueue in ``MainActorWorkQueue`` to the end of its run or its failure. Begin `arg0`: the method's board id in
/// bits 0-31 (0 without a board) and the main work class code in bits 32-39 (``TaskTrace/code(_:)``). End `arg0`:
/// an ``Outcome``. The slice is written only while the `control` category records; a written begin always gets
/// its end.
struct ControlRequestTrace: Sendable {
    /// How the request left the queue: the end record's `arg0`. Fixed codes.
    enum Outcome: UInt64 {
        /// It ran (its work returned or threw).
        case ran = 0
        /// It failed while queued (its deadline passed) and never ran.
        case expired = 1
        /// The queue was full: it never queued.
        case busy = 2

        /// The outcome of a request that failed with `error` before it ran.
        init(_ error: ControlError) {
            self = error.code == "busy" ? .busy : .expired
        }
    }

    private let runtime: TraceRuntime
    private let id: UInt64

    private static var name: UInt16 { SignpostName.controlRequest.rawValue }
    private static var categoryBit: UInt8 { SignpostCategory.control.traceBit }

    /// Begins the slice of a request for `owner` in `workClass`; nil when the `control` category is off.
    static func begin(on runtime: TraceRuntime, owner: MainTaskOwner?, workClass: MainWorkClass) -> ControlRequestTrace? {
        guard runtime.isEnabled(categoryBit: categoryBit) else { return nil }
        let id = runtime.nextAsyncScope()
        let arg0 = UInt64(truncatingIfNeeded: owner?.traceID ?? 0) | UInt64(truncatingIfNeeded: TaskTrace.code(workClass)) << 32
        guard runtime.write(name: name, categoryBit: categoryBit, phase: .asyncBegin, flags: .asyncID, arg0: arg0,
                            arg1: id) else { return nil }
        return ControlRequestTrace(runtime: runtime, id: id)
    }

    /// Ends the slice.
    func end(_ outcome: Outcome) {
        runtime.writeEnd(name: Self.name, categoryBit: Self.categoryBit, phase: .asyncEnd, flags: .asyncID,
                         arg0: outcome.rawValue, arg1: id)
    }
}

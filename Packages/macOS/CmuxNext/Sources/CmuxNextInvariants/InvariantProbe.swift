/// The producer's side of the invariant framework (plans/cmux-next/invariants-DESIGN.md section 2.2): a value the
/// composition root hands to a producer. In Debug and bench builds it forwards to the app's ``InvariantRegistry``.
/// In Release it is an empty struct, ``init()`` is its only initializer and every call is an empty inlined call, so
/// a probe at a write costs nothing there and builds no detail string (`@autoclosure`).
///
/// ```swift
/// probe.touch(.tabs, .window(state.id))          // the rules that read `tabs` run at the end of this turn
/// probe.fail("M1", .machine(id), "\(detail)")    // a call-site checker found its rule broken
/// ```
@MainActor
public struct InvariantProbe {
    #if DEBUG || CMUX_BENCH_HOOKS
    @usableFromInline weak var registry: InvariantRegistry?

    /// A probe that forwards to `registry` (nil: reports nowhere).
    public init(registry: InvariantRegistry?) {
        self.registry = registry
    }
    #endif

    /// A probe that reports nowhere: the only one in Release.
    public init() {}

    /// The state under `key` changed for `subject`: the rules that read `key` run at the end of this turn.
    @inlinable @inline(__always)
    public func touch(_ key: InvariantKey, _ subject: InvariantSubject) {
        #if DEBUG || CMUX_BENCH_HOOKS
        registry?.touch(key, subject)
        #endif
    }

    /// A call-site checker found `id` broken for `subject` (it checks a call, not the state after a turn): the
    /// violation goes to the same ledger as the rules', with trigger kind `inline`.
    @inlinable @inline(__always)
    public func fail(_ id: InvariantID, _ subject: InvariantSubject, _ detail: @autoclosure () -> String,
                     fileID: StaticString = #fileID, line: UInt = #line) {
        #if DEBUG || CMUX_BENCH_HOOKS
        registry?.fail(id, subject, detail(), fileID: fileID, line: line)
        #endif
    }
}

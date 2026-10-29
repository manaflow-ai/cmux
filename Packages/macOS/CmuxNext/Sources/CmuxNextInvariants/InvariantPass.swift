#if DEBUG || CMUX_BENCH_HOOKS
/// One run of the due rules (plans/cmux-next/invariants-DESIGN.md section 2.2): what triggered it, which subjects
/// changed under each key, and a memo so every rule of the pass shares one walk (one `InputObservation`).
@MainActor
public final class InvariantPass {
    public let trigger: InvariantTrigger
    /// A turn in which an action ran, or a full check (`debug.invariants {check: true}`): every subject counts as
    /// dirty.
    public let isFull: Bool
    /// The pass's time, which liveness rules measure their waits against.
    public let now: ContinuousClock.Instant
    private let touched: [InvariantKey: Set<InvariantSubject>]
    private let clock: @MainActor () -> ContinuousClock.Instant
    private var memos: [String: Any] = [:]
    private var memoDepth = 0
    /// Time spent building memos (outermost builds only): a rule is not charged for a shared walk it happened to
    /// build first.
    private(set) var memoTime: Duration = .zero

    init(trigger: InvariantTrigger, touched: [InvariantKey: Set<InvariantSubject>], isFull: Bool,
         now: ContinuousClock.Instant, clock: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.trigger = trigger
        self.touched = touched
        self.isFull = isFull
        self.now = now
        self.clock = clock
    }

    /// The subjects whose state under `key` changed this turn; nil when every subject counts (``isFull``).
    public func dirty(_ key: InvariantKey) -> Set<InvariantSubject>? {
        isFull ? nil : touched[key] ?? []
    }

    /// Whether anything under `key` changed this turn (always true when ``isFull``).
    public func isDirty(_ key: InvariantKey) -> Bool {
        isFull || touched[key] != nil
    }

    /// The value `build` makes, built once per pass under `key`: the rules of a pass that read the same live state
    /// share one walk.
    public func memo<T>(_ key: String, _ build: () -> T) -> T {
        if let value = memos[key] as? T { return value }
        let start = memoDepth == 0 ? clock() : nil
        memoDepth += 1
        let value = build()
        memoDepth -= 1
        if let start { memoTime += clock() - start }
        memos[key] = value
        return value
    }
}
#endif

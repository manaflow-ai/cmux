#if DEBUG || CMUX_BENCH_HOOKS
/// One run of the due rules (plans/cmux-next/invariants-DESIGN.md section 2.2): what triggered it, which subjects
/// changed under each key, and a memo so every rule of the pass shares one walk (one `InputObservation`).
///
/// It also records what each rule's `read` covered, so a signature is cleared only by a run that looked at its
/// subject: a read that asks ``dirty(_:)`` covers only those subjects, a read that never asks covers every subject,
/// and ``skip(_:)`` takes one out (a window in a live resize). A memo build is a shared walk, not a choice of scope:
/// what it asks does not count.
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
    /// The subjects the running rule's read asked for with ``dirty(_:)``; nil while it asked for none.
    private var asked: Set<InvariantSubject>?
    /// The subjects the running rule's read said it did not check.
    private var skipped: Set<InvariantSubject> = []

    init(trigger: InvariantTrigger, touched: [InvariantKey: Set<InvariantSubject>], isFull: Bool,
         now: ContinuousClock.Instant, clock: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.trigger = trigger
        self.touched = touched
        self.isFull = isFull
        self.now = now
        self.clock = clock
    }

    /// The subjects whose state under `key` changed this turn; nil when every subject counts (``isFull``). A read that
    /// asks covers only the subjects it was given.
    public func dirty(_ key: InvariantKey) -> Set<InvariantSubject>? {
        guard !isFull else { return nil }
        let subjects = touched[key] ?? []
        if memoDepth == 0 { asked = (asked ?? []).union(subjects) }
        return subjects
    }

    /// Every subject touched under any of `keys` this turn; nil when every subject counts (``isFull``), or when one
    /// of them is ``InvariantSubject/app`` (a change no producer could name). For a memo that rebuilds only what
    /// changed: it does not narrow the running rule's coverage.
    public func touchedSubjects(_ keys: Set<InvariantKey>) -> Set<InvariantSubject>? {
        guard !isFull else { return nil }
        var subjects = Set<InvariantSubject>()
        for key in keys { subjects.formUnion(touched[key] ?? []) }
        return subjects.contains(.app) ? nil : subjects
    }

    /// Whether anything under `key` changed this turn (always true when ``isFull``).
    public func isDirty(_ key: InvariantKey) -> Bool {
        isFull || touched[key] != nil
    }

    /// The running rule's read checked exactly `subjects` (with any it asked for through ``dirty(_:)``): for a read
    /// that picks its subjects from ``touchedSubjects(_:)`` and reports on others (a window touched, its panes found).
    public func checked(_ subjects: Set<InvariantSubject>) {
        guard !isFull else { return }
        asked = (asked ?? []).union(subjects)
    }

    /// The running rule's read did not check `subject` now (a level precondition for that subject only: a window in
    /// a live resize): a signature reported for it stays reported, and stays unreported, until a run checks it.
    public func skip(_ subject: InvariantSubject) {
        skipped.insert(subject)
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

    /// Starts recording what one rule's read covers.
    func beginRule() {
        asked = nil
        skipped = []
    }

    /// What the rule's read covered since ``beginRule()``.
    func coverage() -> InvariantCoverage {
        InvariantCoverage(subjects: isFull ? nil : asked, skipped: skipped)
    }
}

/// What one run of a rule looked at: every subject (`subjects` nil) or only `subjects`, less `skipped`. Only a
/// covered signature can clear.
struct InvariantCoverage: Sendable {
    var subjects: Set<InvariantSubject>?
    var skipped: Set<InvariantSubject>

    static let everything = InvariantCoverage(subjects: nil, skipped: [])

    func covers(_ subject: InvariantSubject) -> Bool {
        !skipped.contains(subject) && (subjects?.contains(subject) ?? true)
    }
}
#endif

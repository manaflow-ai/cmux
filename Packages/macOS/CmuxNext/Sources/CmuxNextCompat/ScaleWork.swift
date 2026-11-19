/// Counts the work one change does in the paths that must stay flat as sessions grow (goal
/// sessions-2000-attached: per-update cost at 2,000 sessions within 1.2x of 50), for one task: a test sets a
/// counter for the task that makes the change and each counted site adds what it walked. With no counter set (the
/// app), `add` reads one task local and does nothing else.
///
/// ```swift
/// let work = ScaleWork()
/// ScaleWork.$current.withValue(work) { feed.handle(change) }
/// #expect(work.total < budget)
/// ```
public final class ScaleWork: Sendable {
    /// What a site counts.
    public enum Kind: String, CaseIterable, Sendable {
        /// Sessions (lanes, records, rows) a site visited one by one.
        case lanesWalked = "lanes_walked"
        /// Sets or maps built over every session.
        case setsBuilt = "sets_built"
        /// Whole rebuilds of a reader's model from every session.
        case rebuilds
        /// Sidebar band rows visited while placing the transient rows.
        case bandRows = "band_rows"
        /// Whole lists laid over a store (every session of a watch written again).
        case listReloads = "list_reloads"
        /// Steps of a binary search into a sorted list of sessions: O(log n), so not in ``total``.
        case probes
    }

    /// The counter of the task that makes the change; nil counts nothing.
    @TaskLocal public static var current: ScaleWork?

    private let counts = Mutex<[Kind: Int]>([:])

    public init() {}

    /// The count of `kind` so far.
    public subscript(kind: Kind) -> Int { counts.withLock { $0[kind] ?? 0 } }

    /// Every kind's count so far.
    public var all: [Kind: Int] { counts.withLock { $0 } }

    /// Every kind's count but ``Kind/probes``, summed: the work that would grow with the sessions.
    public var total: Int { counts.withLock { $0.filter { $0.key != .probes }.values.reduce(0, +) } }

    /// Adds `amount` of `kind` when a counter is set for the current task.
    @inline(__always)
    public static func add(_ kind: Kind, _ amount: Int = 1) {
        guard let current, amount != 0 else { return }
        current.counts.withLock { $0[kind, default: 0] += amount }
    }
}

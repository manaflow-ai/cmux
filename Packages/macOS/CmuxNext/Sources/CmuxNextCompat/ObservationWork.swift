/// Counts the items an observer's work visits after a change, for the tasks started under one counter: a
/// test sets a counter around the start of an observer, so the observer's tasks (and the tasks they start)
/// carry it, lets the observer settle, resets the counter, makes ONE change and reads what that change cost.
///
/// ``ObservationWakes`` counts how many observers a change wakes; this counts what a woken observer then
/// does. One wake that walks every workspace of the session passes a wake count and fails here: the work
/// after a change of one item must be O(changed + shown), the same number in a session of 60 workspaces
/// and in one of 826 (plans/cmux-next/PATTERNS.md P3, "Go past Chrome" in CLAUDE.md).
///
/// With no counter set (the app), ``visited(_:_:)`` reads one task local and does nothing else.
///
/// ```swift
/// let work = ObservationWork()
/// ObservationWork.$current.withValue(work) { favicons.start(workspaces: ..., favicons: ...) }
/// await settled()
/// work.reset()
/// tab.faviconURL = "https://example.com/icon.png"
/// await settled()
/// #expect(work.count <= 8)
/// ```
public final class ObservationWork: Sendable {
    /// The counter of the task that started the observer; nil counts nothing.
    @TaskLocal public static var current: ObservationWork?

    private let visits = Mutex<[String: Int]>([:])

    /// A counter at zero.
    public init() {}

    /// The items visited so far.
    public var count: Int { visits.withLock { $0.values.reduce(0, +) } }

    /// The items visited so far, by the step that visited them (`ObservedItems.list`, `ObservedItems.map`, a join's name).
    public var byStep: [String: Int] { visits.withLock { $0 } }

    /// Back to zero.
    public func reset() { visits.withLock { $0 = [:] } }

    /// `step` visited `count` items (models of a list, items of a join): counted when a counter is set for the
    /// current task. Call it once per pass with the pass's size, not once per item.
    package static func visited(_ count: Int, _ step: StaticString) {
        guard let current else { return }
        current.visits.withLock { $0["\(step)", default: 0] += count }
    }
}

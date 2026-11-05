/// Counts the observation trackings a change wakes, for one task: a test sets a counter for the task that makes the
/// change, and every will-set that reaches an `ObservationStream`, a `SingleArmedTracking` or the Browser's
/// `ObservationLoop` during that task's change adds one. A local change must wake O(changed items) observers, never
/// O(session) (plans/cmux-next/PATTERNS.md P3, "Go past Chrome" in CLAUDE.md): a test compares the count of one New
/// Terminal Tab in a small session with the count in a STRESS-sized one.
///
/// Only will-sets that run inside the change (synchronously, in the task the counter is set for) are counted; a direct
/// `withObservationTracking` outside these wrappers is not. With no counter set (the app), `record()` reads one task
/// local and does nothing else.
///
/// ```swift
/// let wakes = ObservationWakes()
/// ObservationWakes.$current.withValue(wakes) { store.intend(.createTab(...), transaction: id) }
/// #expect(wakes.count == expected)
/// ```
public final class ObservationWakes: Sendable {
    /// The counter of the task that makes the change; nil counts nothing.
    @TaskLocal public static var current: ObservationWakes?

    private let wakes = Mutex(0)

    /// A counter at zero.
    public init() {}

    /// The wakes counted so far.
    public var count: Int { wakes.withLock { $0 } }

    /// One tracking woke: counted when a counter is set for the current task.
    package static func record() {
        current?.wakes.withLock { $0 += 1 }
    }
}

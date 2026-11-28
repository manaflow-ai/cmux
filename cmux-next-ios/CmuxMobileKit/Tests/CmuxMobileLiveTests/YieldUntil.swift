import Testing

/// Yields until `done()` holds, bounded and named: the kit's test waits, in place of a bare
/// `while !done() { await Task.yield() }`.
///
/// A bare yield loop never checks cancellation, so a suite's `.timeLimit` cannot stop it: a
/// condition that never comes true held the simulator step silent to its 30 min job timeout
/// (cmux-next-ios-kit runs 45653800020, 45711133169, 45731739192, 45738347026). This wait ends on
/// cancellation or after `budget` of polling, and records a failure at the caller's line.
/// The budget counts at most 100 ms per poll, so a runner stall of 30 to 50 s (AwakeDeadline's
/// note) costs one poll, not the whole budget. Each test target keeps its own copy.
@discardableResult
func yieldUntil(
    _ what: @autoclosure () -> String = "the condition",
    within budget: Duration = .seconds(30),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ done: () -> Bool
) async -> Bool {
    var left = budget
    var last = ContinuousClock.now
    while !done() {
        let now = ContinuousClock.now
        left -= min(now - last, .milliseconds(100))
        last = now
        if Task.isCancelled || left <= .zero {
            Issue.record("waited \(budget) for \(what()) and it never held", sourceLocation: sourceLocation)
            return false
        }
        await Task.yield()
    }
    return true
}

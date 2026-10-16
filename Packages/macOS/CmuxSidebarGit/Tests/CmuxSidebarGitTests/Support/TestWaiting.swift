import Foundation
import Testing

/// Wall-clock backstop for every wait in this suite.
///
/// Waits here are event-driven or deadline-bounded, so a passing wait returns
/// the moment its condition holds and only a hang pays this budget. Never
/// bound a wait by a `Task.yield()` count: probe work runs on a detached
/// `.utility` task, and a test spinning on yields at a higher priority can
/// finish thousands of yields (about 0.1 s on a loaded CI runner) before that
/// task is scheduled at all.
let sidebarGitTestWaitTimeout: Duration = .seconds(30)

/// Suspends until `predicate` holds or `timeout` elapses.
///
/// Sleeps between checks instead of yielding so lower-priority work, such as
/// the detached snapshot probe, gets a thread. On timeout it records an issue
/// that names the budget, then returns `false`.
@MainActor
func waitUntil(
    _ description: String = "condition",
    timeout: Duration = sidebarGitTestWaitTimeout,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard clock.now < deadline else {
            recordWaitTimeout(description, timeout: timeout, sourceLocation: sourceLocation)
            return false
        }
        // A cancelled sleep throws without suspending; stop instead of
        // spinning on the main actor until the deadline.
        do {
            try await Task.sleep(for: .milliseconds(1))
        } catch {
            return false
        }
    }
    return true
}

func recordWaitTimeout(
    _ description: String,
    timeout: Duration,
    sourceLocation: SourceLocation
) {
    Issue.record(
        """
        Timed out after \(timeout) waiting for \(description). The awaited work \
        never ran: a hang, a lost wakeup, or a badly starved runner.
        """,
        sourceLocation: sourceLocation
    )
}

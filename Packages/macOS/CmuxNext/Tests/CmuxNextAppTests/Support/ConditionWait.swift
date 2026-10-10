import Foundation
import Testing

/// Waits (bounded) for state another task delivers, polling every 20 ms.
///
/// A timeout records an Issue at the caller's line with the time waited, so
/// the failure names the condition that never held instead of a later
/// symptom (a nil pane, a missing tab). The caller's line is the condition.
///
/// - Parameters:
///   - what: An optional description added to the timeout Issue.
///   - timeout: How long to wait.
///   - sourceLocation: The waiting call (forwarded by wrappers).
///   - condition: The state to wait for.
@MainActor
func waitForCondition(_ what: String? = nil, timeout: Duration, sourceLocation: SourceLocation,
                      _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let end = start.advanced(by: timeout)
    while !condition(), clock.now < end { try await clock.sleep(for: .milliseconds(20)) } // test-only wait
    guard !condition() else { return }
    let waited = (clock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
    let label = what.map { " (\($0))" } ?? ""
    Issue.record("waitUntil timed out after \(waited): the condition at \(sourceLocation.fileName):\(sourceLocation.line)\(label) never held",
                 sourceLocation: sourceLocation)
}

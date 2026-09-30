import Foundation

/// Yields until `condition` holds or `timeout` of wall-clock time passes.
///
/// A deadline instead of a yield count keeps the wait stable on a busy
/// runner, where each reschedule takes longer.
@MainActor
func dictationWaitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

import Testing

/// Waits until `condition` holds, checking about every 5 ms. It gives
/// up only after `timeout` has passed and it has checked `polls` times, so a
/// main actor stalled by other tests in the full suite still gets turns to
/// run the work this is waiting for.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(5), polls: Int = 200, _ condition: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    var checks = 0
    while ContinuousClock.now < deadline || checks < polls {
        if await condition() { return }
        checks += 1
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never held: \(what)")
}

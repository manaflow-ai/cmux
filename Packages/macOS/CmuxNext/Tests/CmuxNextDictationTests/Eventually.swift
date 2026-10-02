import Testing

/// Waits until `condition` holds, checking every millisecond for up to
/// `timeout`, so a busy CI machine gets real time rather than a yield count.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    if await condition() { return }
    Issue.record("never held: \(what)")
}

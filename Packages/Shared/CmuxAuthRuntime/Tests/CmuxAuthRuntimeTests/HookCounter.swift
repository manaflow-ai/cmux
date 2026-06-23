/// Counts hook invocations from synchronous main-actor hooks.
@MainActor
final class HookCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

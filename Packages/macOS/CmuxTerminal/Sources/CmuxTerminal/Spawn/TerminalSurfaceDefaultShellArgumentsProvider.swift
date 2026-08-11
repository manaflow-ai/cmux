/// Resolves and caches default shell arguments away from the main actor.
final class TerminalSurfaceDefaultShellArgumentsProvider: Sendable {
    private let task: Task<[String], Never>

    init(resolve: @escaping @Sendable () -> [String]) {
        task = Task.detached(priority: .utility, operation: resolve)
    }

    func arguments(
        fallback: [String],
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> [String] {
        let attempt = TerminalSurfaceDefaultShellArgumentsAttempt(fallback: fallback)
        await attempt.start(task: task, deadline: deadline, clock: clock)
        return await withTaskCancellationHandler {
            await attempt.value()
        } onCancel: {
            attempt.cancel()
        }
    }
}

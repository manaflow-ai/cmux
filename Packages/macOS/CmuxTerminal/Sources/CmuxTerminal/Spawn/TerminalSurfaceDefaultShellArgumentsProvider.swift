/// Resolves and caches default shell arguments away from the main actor.
final class TerminalSurfaceDefaultShellArgumentsProvider: Sendable {
    private let task: Task<[String], Never>

    init(resolve: @escaping @Sendable () -> [String]) {
        task = Task.detached(priority: .utility, operation: resolve)
    }

    func arguments() async -> [String] {
        await task.value
    }
}

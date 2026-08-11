internal import Foundation

/// Resolves and caches default shell arguments away from the main actor.
final class TerminalSurfaceDefaultShellArgumentsProvider: Sendable {
    private let state: TerminalSurfaceDefaultShellArgumentsState
    private let lookupTask: Task<Void, Never>

    init(resolve: @escaping @Sendable () -> [String]) {
        let state = TerminalSurfaceDefaultShellArgumentsState()
        self.state = state
        lookupTask = Task.detached(priority: .utility) {
            let arguments = resolve()
            await state.publish(arguments)
        }
    }

    deinit {
        lookupTask.cancel()
    }

    func arguments(
        fallback: [String],
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> [String] {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await state.value(
                identifier: identifier,
                fallback: fallback,
                deadline: deadline,
                clock: clock
            )
        } onCancel: {
            state.cancelWaiter(identifier, with: fallback)
        }
    }
}

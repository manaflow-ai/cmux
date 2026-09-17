public import Foundation

/// Starts one fixed bundle-resource inspection outside the main actor and
/// shares its immutable result across terminal launches.
public final class TerminalSurfaceLaunchResourceProvider: Sendable {
    private let state: TerminalSurfaceLaunchResourceProviderState
    private let task: Task<TerminalSurfaceLaunchResourceSnapshot, Never>

    /// Starts one asynchronous inspection of the supplied resource directory.
    public init(
        resourceURL: URL?,
        isExecutableFile: @escaping @Sendable (String) -> Bool,
        directoryExists: @escaping @Sendable (String) -> Bool
    ) {
        let state = TerminalSurfaceLaunchResourceProviderState()
        self.state = state
        task = Task.detached(priority: .utility) {
            let snapshot = TerminalSurfaceLaunchResourceSnapshot(
                resourceURL: resourceURL,
                isExecutableFile: isExecutableFile,
                directoryExists: directoryExists
            )
            await state.install(snapshot)
            return snapshot
        }
    }

    deinit {
        task.cancel()
    }

    /// Waits for the shared resource snapshot until cancellation.
    public func snapshot() async -> TerminalSurfaceLaunchResourceSnapshot {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await state.value(identifier: identifier)
        } onCancel: {
            state.cancelWaiter(identifier)
        }
    }

    /// Waits for the shared resource snapshot until the injected deadline.
    public func snapshot(
        deadline: Duration,
        clock: any Clock<Duration>
    ) async -> TerminalSurfaceLaunchResourceSnapshot {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await state.value(
                identifier: identifier,
                deadline: deadline,
                clock: clock
            )
        } onCancel: {
            state.cancelWaiter(identifier)
        }
    }

    /// Returns the snapshot only when the inspection has completed.
    public func completedSnapshot() async -> TerminalSurfaceLaunchResourceSnapshot? {
        await state.current()
    }
}

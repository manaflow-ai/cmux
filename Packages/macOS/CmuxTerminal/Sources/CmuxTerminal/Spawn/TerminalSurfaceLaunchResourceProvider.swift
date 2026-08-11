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

    /// Waits for and returns the shared resource snapshot.
    public func snapshot() async -> TerminalSurfaceLaunchResourceSnapshot {
        await task.value
    }

    /// Returns the snapshot only when the inspection has completed.
    public func completedSnapshot() async -> TerminalSurfaceLaunchResourceSnapshot? {
        await state.current()
    }
}

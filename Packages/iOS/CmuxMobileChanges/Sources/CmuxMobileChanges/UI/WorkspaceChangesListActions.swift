/// User actions emitted by ``WorkspaceChangesListView``.
public struct WorkspaceChangesListActions: Sendable {
    /// Selects a file by its stable position in the snapshot.
    public let onSelectFile: @MainActor @Sendable (Int) -> Void
    /// Refreshes the full changed-file snapshot.
    public let onRefresh: @MainActor @Sendable () async -> Void
    /// Retries a failed initial request.
    public let onRetry: @MainActor @Sendable () -> Void

    /// Creates list actions.
    /// - Parameters:
    ///   - onSelectFile: File selection callback.
    ///   - onRefresh: Pull-to-refresh callback.
    ///   - onRetry: Failure retry callback.
    public init(
        onSelectFile: @escaping @MainActor @Sendable (Int) -> Void,
        onRefresh: @escaping @MainActor @Sendable () async -> Void,
        onRetry: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onSelectFile = onSelectFile
        self.onRefresh = onRefresh
        self.onRetry = onRetry
    }
}

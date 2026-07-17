/// Callbacks emitted by the rendering core for data operations owned by its host.
public struct DiffScreenActions: Sendable {
    /// Requests loading a gated large file.
    public let loadLargeFile: @MainActor @Sendable (DiffFileSnapshot) -> Void
    /// Retries loading a failed file.
    public let retryFile: @MainActor @Sendable (DiffFileSnapshot) -> Void
    /// Requests additional context around a hunk.
    public let expandContext: @MainActor @Sendable (DiffContextExpansionRequest) -> Void

    /// Creates the host action bundle.
    /// - Parameters:
    ///   - loadLargeFile: Called when the user opens a large patch.
    ///   - retryFile: Called when the user retries a failed patch.
    ///   - expandContext: Called for hunk context expansion controls.
    public init(
        loadLargeFile: @escaping @MainActor @Sendable (DiffFileSnapshot) -> Void,
        retryFile: @escaping @MainActor @Sendable (DiffFileSnapshot) -> Void,
        expandContext: @escaping @MainActor @Sendable (DiffContextExpansionRequest) -> Void
    ) {
        self.loadLargeFile = loadLargeFile
        self.retryFile = retryFile
        self.expandContext = expandContext
    }
}

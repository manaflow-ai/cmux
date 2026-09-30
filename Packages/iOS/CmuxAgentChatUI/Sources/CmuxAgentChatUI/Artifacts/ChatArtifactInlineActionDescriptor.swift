/// Equatable toolbar state reported by a loaded inline artifact preview.
public struct ChatArtifactInlineActionDescriptor: Equatable, Sendable {
    /// A path-and-preview-state identity used to reject stale action requests.
    public let id: String
    /// Actions valid for the loaded preview state.
    public let actions: [ChatArtifactAction]
    /// Whether an asynchronous file action is currently running.
    public let isRunning: Bool

    /// Creates toolbar state for an inline artifact preview.
    /// - Parameters:
    ///   - id: A path-and-preview-state identity.
    ///   - actions: Actions valid for the loaded preview state.
    ///   - isRunning: Whether an asynchronous file action is currently running.
    public init(id: String, actions: [ChatArtifactAction], isRunning: Bool) {
        self.id = id
        self.actions = actions
        self.isRunning = isRunning
    }
}

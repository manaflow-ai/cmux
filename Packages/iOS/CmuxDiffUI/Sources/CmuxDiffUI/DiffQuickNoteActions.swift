/// Host-owned chat actions available from a diff quick-note sheet.
public struct DiffQuickNoteActions: Sendable {
    /// Whether the workspace has an agent chat session that can receive the note.
    public let isAvailable: Bool
    /// Sends a formatted prompt through the host's composer send path.
    public let send: @MainActor @Sendable (String) async -> Void
    /// Places a formatted prompt in the host's existing composer.
    public let editInComposer: @MainActor @Sendable (String) -> Void

    /// Creates a quick-note action bundle.
    /// - Parameters:
    ///   - isAvailable: Whether an agent chat session can receive or edit the note.
    ///   - send: Sends the already-formatted prompt.
    ///   - editInComposer: Prefills the existing composer with the prompt.
    public init(
        isAvailable: Bool,
        send: @escaping @MainActor @Sendable (String) async -> Void,
        editInComposer: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.isAvailable = isAvailable
        self.send = send
        self.editInComposer = editInComposer
    }
}

/// A task identity reported by a Claude task-tool hook.
///
/// Both fields must match one persisted task record exactly before an
/// otherwise unrelated team task directory can be bound to a hook session.
public struct ClaudeTaskIdentity: Sendable, Equatable {
    /// Claude's stable task identifier.
    public let id: String

    /// The task subject exactly as reported by the hook.
    public let subject: String

    /// Creates an identity used to prove ownership of a task directory.
    ///
    /// - Parameters:
    ///   - id: Claude's stable task identifier.
    ///   - subject: The task subject exactly as reported by the hook.
    public init(id: String, subject: String) {
        self.id = id
        self.subject = subject
    }
}

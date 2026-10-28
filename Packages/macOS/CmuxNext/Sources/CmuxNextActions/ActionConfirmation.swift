/// The remote half of an action whose local change is already shown (``ActionEffect/applied(_:)``):
/// the command to send, and how to take the local change back when it fails.
///
/// The registry, not the handler, starts ``send`` (after the handler returned, so nothing awaits on
/// the input's turn), tracks it for a caller that waits for the effect (the control socket), and on
/// failure runs ``rollback`` and shows the failure (``ActionRegistry/remoteFailureObserver``).
///
/// ```swift
/// // A store intent shows now; the daemon's reply settles it, a failure rolls it back.
/// return daemon.intent("rename-pane", .renamePane(pane: handle, name: name)) { try await $0.renamePane(handle, to: name) }
/// ```
public struct ActionConfirmation {
    /// Sends the command; returns nil when it applied, else why it failed.
    public let send: @MainActor () async -> ActionWorkFailure?
    /// Takes the local change back after a failure; nil when the sender rolls back by itself (a
    /// store intent leaves the log on failure).
    public let rollback: (@MainActor (ActionWorkFailure) -> Void)?

    /// - Parameters:
    ///   - send: The command; nil on success, else the failure.
    ///   - rollback: Undoes the shown change after a failure, or nil when `send` does.
    public init(send: @escaping @MainActor () async -> ActionWorkFailure?,
                rollback: (@MainActor (ActionWorkFailure) -> Void)? = nil) {
        self.send = send
        self.rollback = rollback
    }
}

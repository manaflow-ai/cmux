/// The remote half of an action whose local change is already shown (``ActionEffect/applied(_:)``):
/// the command to send, and how to take the local change back when it fails.
///
/// The registry, not the handler, starts ``send`` (after the handler returned, so nothing awaits on
/// the input's turn), tracks it for a caller that waits for the effect (the control socket), and on
/// failure runs ``rollback`` and shows the failure (``ActionRegistry/remoteFailureObserver``).
///
/// ```swift
/// // A store intent shows now; the daemon's reply settles it, a failure rolls it back.
/// return daemon.intentEffect("rename-pane", .renamePane(pane: handle, name: name)) { try await $0.renamePane(handle, to: name) }
///
/// // A change shown outside the store: the rollback takes it back.
/// row.color = color
/// return .applied(ActionConfirmation(send: { await daemon.failure("set-color") { try await $0.setColor(id, color) } },
///                                    rollback: { _ in row.color = previous }))
/// ```
///
/// A confirmation without a rollback is counted (``ActionRegistry/hiddenWaitRuns``,
/// ``ActionHiddenWait/unconfirmedApply``) unless it is a store intent's (``storeIntent(send:)``):
/// nothing else takes the change back, so either nothing showed first or a failure leaves it shown.
public struct ActionConfirmation {
    /// Sends the command; returns nil when it applied, else why it failed.
    public let send: @MainActor () async -> ActionWorkFailure?
    /// Takes the local change back after a failure; nil when the sender rolls back by itself (a
    /// store intent leaves the log on failure).
    public let rollback: (@MainActor (ActionWorkFailure) -> Void)?
    /// Whether `send` takes the shown change back by itself: a store intent (``storeIntent(send:)``).
    let rollsBackItself: Bool

    /// - Parameters:
    ///   - send: The command; nil on success, else the failure.
    ///   - rollback: Undoes the shown change after a failure. Nil only for a change nothing needs to
    ///     take back; such a run is counted as ``ActionHiddenWait/unconfirmedApply``. A store intent
    ///     uses ``storeIntent(send:)``.
    public init(send: @escaping @MainActor () async -> ActionWorkFailure?,
                rollback: (@MainActor (ActionWorkFailure) -> Void)? = nil) {
        self.send = send
        self.rollback = rollback
        rollsBackItself = false
    }

    private init(intentSend send: @escaping @MainActor () async -> ActionWorkFailure?) {
        self.send = send
        rollback = nil
        rollsBackItself = true
    }

    /// The confirmation of a store intent already shown: `send` sends the command, and the store
    /// takes the intent out by itself when it fails (`DaemonService.intentEffect`).
    ///
    /// - Parameter send: The command; nil on success, else the failure.
    /// - Returns: A confirmation with no rollback of its own.
    public static func storeIntent(send: @escaping @MainActor () async -> ActionWorkFailure?) -> ActionConfirmation {
        ActionConfirmation(intentSend: send)
    }
}

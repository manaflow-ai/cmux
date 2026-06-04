internal import CmuxMobileRPC
internal import CmuxMobileShellModel

/// Facade-side collaborators ``MobileConnectionCoordinator`` needs from
/// ``MobileShellComposite``.
///
/// The connection coordinator owns the connection lifecycle but not the
/// sign-in gate, the workspace list, the terminal output pipeline, or the
/// remote-operation tasks; those stay with the facade and its other carved
/// pieces. This seam keeps that dependency one-directional and lets tests
/// drive the coordinator against a scripted context.
@MainActor
protocol MobileConnectionContext: AnyObject {
    /// Whether the user is signed in; every pairing attempt and remote
    /// response is discarded after sign-out.
    var isSignedIn: Bool { get }

    /// The currently selected workspace, read when deciding whether a full
    /// workspace-list refresh may retarget selection to the active ticket.
    var selectedWorkspaceID: MobileWorkspacePreview.ID? { get }

    /// Tears down everything scoped to the previous client after
    /// `remoteClient` is cleared: stops event listening, cancels
    /// remote-operation tasks, and resets output sequence tracking.
    func remoteClientWasCleared()

    /// Starts the terminal push-event listener after a client connects.
    func connectionDidEstablish()

    /// Cancels the facade's connection-scoped tasks (create workspace/
    /// terminal, output subscription refresh, workspace-list refresh).
    func cancelRemoteOperationTasks()

    /// Drops any buffered raw terminal input when a new pairing attempt or
    /// teardown begins.
    func clearRawTerminalInputBuffer()

    /// Applies a decoded remote workspace list to the workspace model.
    func applyRemoteWorkspaceList(
        _ response: MobileSyncWorkspaceListResponse,
        preferActiveTicketTarget: Bool,
        mergeExistingWorkspaces: Bool
    )

    /// Reconciles the selected terminal after the workspace list changed.
    func syncSelectedTerminalForWorkspace()

    /// Replaces the workspace list with the ticket's single attached
    /// workspace/terminal (preview mode without a sync runtime).
    func applyPreviewTicket(workspaceID: String, terminalID: String?)

    /// Ensures a workspace/terminal is selected after the preview host
    /// connects without changing an existing selection.
    func ensurePreviewWorkspaceSelection()
}

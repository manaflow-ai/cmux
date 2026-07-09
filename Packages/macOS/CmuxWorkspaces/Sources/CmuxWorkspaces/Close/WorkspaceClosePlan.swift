public import Foundation

/// The machine-diffable result of planning a multi-workspace close: the
/// ordered set of workspaces that will close, plus the confirmation strings
/// and the Cmd-D acceptance flag the app-side presenter feeds into its
/// `NSAlert`.
///
/// Plan-vs-apply split: `WorkspaceCloseCoordinator` computes this value from a
/// `WorkspacesModel` snapshot (pure, testable, no AppKit), and the window-side
/// `TabManager` applies it — presenting the confirmation through
/// ``CloseConfirming`` and running the `Workspace`/window teardown the god
/// object still owns. Keeping the plan a value type makes the close sequence
/// diffable against the legacy `closeWorkspacesPlan(for:)` body byte-for-byte.
public struct WorkspaceClosePlan: Sendable, Equatable {
    /// The workspaces to close, in sidebar order.
    public let workspaceIds: [UUID]
    /// Whether this batch closes every workspace in the window (so the window
    /// itself closes, and the confirmation copy is the window variant).
    public let willCloseWindow: Bool
    /// The localized confirmation alert title.
    public let title: String
    /// The localized confirmation alert message (bulleted workspace titles).
    public let message: String
    /// Whether the confirmation alert accepts Cmd-D as confirm (true only when
    /// the batch closes the whole window, matching the legacy `acceptCmdD`).
    public let acceptCmdD: Bool

    /// Creates a fully resolved close plan.
    public init(
        workspaceIds: [UUID],
        willCloseWindow: Bool,
        title: String,
        message: String,
        acceptCmdD: Bool
    ) {
        self.workspaceIds = workspaceIds
        self.willCloseWindow = willCloseWindow
        self.title = title
        self.message = message
        self.acceptCmdD = acceptCmdD
    }
}

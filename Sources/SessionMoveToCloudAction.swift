import CmuxCloud
import CmuxSidebar
import Foundation

/// Starts the bundled `cmux session move` for an app entrypoint and reports how
/// it ended. A protocol so tests can stand in for the child process.
@MainActor
protocol SessionMoveCLILaunching: AnyObject {
    /// False when the CLI could not start; `onCompletion` then never runs.
    func launchSessionMove(
        arguments: [String],
        workingDirectory: URL?,
        onOutput: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (_ succeeded: Bool, _ output: String) -> Void
    ) -> Bool
}

/// Stops Claude at a turn boundary before its session leaves this Mac, and
/// starts it again in place when the move fails.
@MainActor
protocol SessionMoveAgentStopping: AnyObject {
    func stopAgent(workspaceId: UUID, panelId: UUID) async -> AgentHibernationManualRefusal?
    func resumeAgent(workspaceId: UUID, panelId: UUID)
}

/// Move to Cloud: the one path behind the workspace row menu, the terminal
/// context menu and the command palette.
@MainActor
final class SessionMoveToCloudAction {
    static var shared = SessionMoveToCloudAction()
    static let statusKey = "cloud.move"

    init(
        launcher: (any SessionMoveCLILaunching)? = nil,
        stopper: (any SessionMoveAgentStopping)? = nil,
        resolveSnapshot: (@MainActor (Workspace, UUID) -> SessionRestorableAgentSnapshot?)? = nil,
        isCloudEnabled: (@MainActor () -> Bool)? = nil,
        notifyFailure: (@MainActor (_ workspaceId: UUID, _ body: String) -> Void)? = nil
    ) {}

    func canMove(workspace: Workspace, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        nil
    }

    func movablePanelId(in workspace: Workspace) -> UUID? {
        nil
    }

    @discardableResult
    func move(workspace: Workspace, panelId: UUID, machine: String?) -> Task<Void, Never>? {
        nil
    }
}

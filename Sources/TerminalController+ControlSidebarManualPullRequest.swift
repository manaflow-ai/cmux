import CmuxSidebar
import Foundation

extension TerminalController {
    nonisolated func controlSidebarManualPullRequestError(invalidTarget: Bool) -> String {
        let message = invalidTarget ? String(
            localized: "cli.pr.error.workspaceMissing",
            defaultValue: "Workspace not found; run cmux list-workspaces and retry with --workspace."
        ) : String(
            localized: "cli.pr.error.invalidHandoff",
            defaultValue: "Invalid PR handoff; use cmux pr --help."
        )
        return "ERROR: " + message
    }

}

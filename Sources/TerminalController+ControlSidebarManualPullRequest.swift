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

    func controlSidebarAttachManualPullRequest(
        tabArg: String?,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg),
              let status = SidebarPullRequestStatus(rawValue: statusRawValue) else {
            return false
        }
        tab.attachManualPullRequest(number: number, label: label, url: url, status: status, branch: branch)
        return true
    }

    func controlSidebarClearManualPullRequest(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return false }
        tab.clearManualPullRequest()
        return true
    }

}

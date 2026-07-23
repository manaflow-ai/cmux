import CmuxSwiftRender
import Foundation

extension Workspace {
    /// Pull-request values projected for the custom-sidebar interpreter
    /// context (`workspaces[i].pr` / `workspaces[i].prs`). Reads the per-panel
    /// pull-request state in sidebar display order rather than the
    /// focused-panel `pullRequest` mirror: the mirror only refreshes while its
    /// panel is focused, so it is routinely nil for background workspaces that
    /// do have a known open PR.
    func customSidebarPullRequestValues() -> [SwiftValue] {
        customSidebarPullRequestValues(orderedPanelIds: sidebarOrderedPanelIds())
    }

    /// `orderedPanelIds` variant so a caller that already walked the bonsplit
    /// tree for this build (e.g. `customSidebarWorkspaceSnapshot`) does not
    /// pay a second `sidebarOrderedPanelIds()` tree walk.
    func customSidebarPullRequestValues(orderedPanelIds: [UUID]) -> [SwiftValue] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            var fields: [String: SwiftValue] = [
                "number": .int(pullRequest.number),
                "label": .string(pullRequest.label),
                "url": .string(pullRequest.url.absoluteString),
                "status": .string(pullRequest.status.rawValue),
                "stale": .bool(pullRequest.isStale),
            ]
            if let branch = pullRequest.branch { fields["branch"] = .string(branch) }
            return .object(fields)
        }
    }
}

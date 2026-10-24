@testable import CmuxNextSidebar
import Foundation

/// The row features this build has, set on the bench's workspaces as the app sets them: a working
/// row's "Now:" step and a pull request badge on every fourth row (`sidebar.pullRequestBadges`).
/// An older commit timed with `SidebarLagBench` gets an empty copy of this file.
@MainActor
struct SidebarLagFeatures {
    static func decorate(_ w: inout SidebarWorkspace, _ index: Int) {
        if index % 6 == 0 { w.agentWorking = true; w.agentStep = "Reading SidebarListView.swift" }
    }

    static func tick(_ w: inout SidebarWorkspace, _ tick: Int) {
        if w.agentWorking { w.agentStep = "Editing file \(tick % 17)" }
    }

    static func attach(_ model: SidebarModel, _ ids: [WorkspaceID]) {
        var badges: [WorkspaceID: SidebarPullRequestBadge] = [:]
        for (i, id) in ids.enumerated() where i % 4 == 1 {
            badges[id] = SidebarPullRequestBadge(count: 1, status: i % 3 == 0 ? .failing : .passing)
        }
        SidebarSessionTree.shared.pullRequests = badges
    }

    static func detach() { SidebarSessionTree.shared.pullRequests = [:] }
}

import CmuxNextAgentActivity
import CmuxNextDaemon
import Foundation

/// Sample lanes for captures (`sidebar.laneFixture`, Debug, off): every workspace row gets one
/// agent chat in a state picked from its name, so a capture slot, which runs no agents, shows each
/// state a row can name (needs you, working, done, failed, idle) without real sessions. The working
/// one is also a runaway, so a capture shows the usage warning badge.
@MainActor
enum SidebarLaneFixture {
    static let states: [(AgentActivityLane.State, unread: Bool, step: String?)] = [
        (.input, false, "Asking to run the migration"),
        (.working, false, "Running the test suite"),
        (.idle, true, "Opened the pull request"),
        (.failed, false, "Build failed in SidebarLayout.swift"),
        (.idle, false, nil),
    ]

    /// The working sample's usage warnings: a runaway session's badge (acpmux `usageWarnings`).
    static let usageWarnings = [
        "No autocompact cap: context is 412k and only compacts at the model's limit. "
            + "Rotate onto a capped profile (lane-place rotate fleet-coordinator --harness claude-sr2)",
        "Context 412k tokens, above the 400k warning line. Compact it (acpmux send fleet-coordinator /compact) "
            + "or rotate to a fresh session (lane-place rotate fleet-coordinator)",
        "90 subagents started in the last hour, above 40. Open the session to see what it starts; "
            + "cancel its turn to stop it (acpmux session cancel fleet-coordinator)",
    ]

    /// One start for every sample lane, so a read mark on one holds (its stamp keeps its `since`).
    static let since = Date(timeIntervalSinceNow: -7 * 60)

    /// `workspace`'s sample lane; a name always gets the same state, so a capture's rows do too.
    static func lanes(_ workspace: WorkspaceModel) -> [AgentActivityLane] {
        let pick = states[workspace.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % states.count]
        return [AgentActivityLane(id: "fixture:\(workspace.id)", name: workspace.name, title: workspace.name, peer: nil, parent: nil,
                                  state: pick.0, since: since, error: pick.0 == .failed ? pick.step : nil, step: pick.step,
                                  unread: pick.unread, usageWarnings: pick.0 == .working ? usageWarnings : [])]
    }
}

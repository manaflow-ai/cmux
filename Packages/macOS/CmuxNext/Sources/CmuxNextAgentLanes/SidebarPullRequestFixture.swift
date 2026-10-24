import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar

/// Sample pull requests for captures (`sidebar.pullRequestFixture`, Debug, off): every workspace
/// row gets pull requests picked from its name instead of GitHub's answers, so a capture slot, which
/// reads no GitHub, shows each mark a row can draw. The rows still follow
/// `sidebar.workspaceRow.pullRequest` (off by default): with it off they draw none.
@MainActor
enum SidebarPullRequestFixture {
    static let picks: [[SidebarPullRequestItem.State]] = [
        [.failing],
        [.merged, .merged],
        [.passing],
        [.draft, .passing, .merged],
        [],
    ]

    /// Each workspace's sample badge; a name always gets the same pull requests, so a capture's rows do too.
    static func badges(_ workspaces: [WorkspaceModel]) -> [SidebarWorkspaceID: SidebarPullRequestBadge] {
        var badges: [SidebarWorkspaceID: SidebarPullRequestBadge] = [:]
        for workspace in workspaces {
            let pick = picks[workspace.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % picks.count]
            let items = pick.enumerated().map { index, state in
                SidebarPullRequestItem(url: "https://github.com/example/app/pull/\(100 + index)", repository: "example/app",
                                       number: 100 + index, title: "\(workspace.name) (\(state.rawValue))", state: state,
                                       additions: 12 * (index + 1), deletions: 3 * (index + 1))
            }
            badges[SidebarWorkspaceID(workspace.id)] = SidebarPullRequestBadge.combining(items: items)
        }
        return badges
    }
}

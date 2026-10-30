public import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSidebar

extension SidebarSessionTreeFeed {
    /// Whether a pull request of `lane`'s (its folder's branch's, or one it opened) has failing
    /// checks, as the session tree's pull request reads last answered: the Priority view's Red CI
    /// and the rows' chip. It asks GitHub nothing of its own; the reads are the tree's
    /// (``SidebarPullRequestStore``: the person's gh, two calls at a time, five minutes fresh),
    /// which run while the tree or the Priority view is on. False while both are off, or before
    /// that chat's pull requests were read. Read inside an observation scope, a new answer redraws.
    public func checksFailing(_ lane: AgentActivityLane) -> Bool {
        Self.checksFailing(lane, answers: pullRequests.answers, sections: DesignSettings.shared.sidebarSections)
    }

    /// The pull request reads run: the session tree or the Priority view is on.
    static func readsPullRequests(_ sections: SidebarSectionsPreferences) -> Bool {
        sections.sessionTree || sections.priorityViewEnabled
    }

    /// The badge reads run for the rows: `sidebar.pullRequestBadges` and some row shows pull requests
    /// (`sidebar.workspaceRow.pullRequest`, off by default), so a sidebar that draws none asks GitHub nothing.
    static func readsBadges(_ sections: SidebarSectionsPreferences) -> Bool {
        SidebarTunables.pullRequestBadges.value && sections.workspaceRow.showsAnywhere(.pullRequest)
    }

    /// Whether any of `lane`'s answers (its folder's branch's pull request, each one it opened) is
    /// open with failing checks, as its badge line reads (``item(_:)``), while the reads run.
    static func checksFailing(_ lane: AgentActivityLane, answers: [String: AgentPanePullRequest],
                              sections: SidebarSectionsPreferences) -> Bool {
        guard readsPullRequests(sections) else { return false }
        return asks([lane]).contains { answers[$0].map { item($0).state == .failing } ?? false }
    }
}

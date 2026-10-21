public import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextDesign

extension SidebarSessionTreeFeed {
    /// Whether a pull request of `lane`'s (its folder's branch's, or one it opened) has failing
    /// checks, as the session tree's badge last read it: the Priority view's Red CI and the rows'
    /// chip. It asks GitHub nothing of its own (one shared quota), so it is false while the tree is
    /// off (`sidebar.sessionTree`) or has not read that chat's pull requests yet. Read inside an
    /// observation scope, a new answer redraws.
    public func checksFailing(_ lane: AgentActivityLane) -> Bool {
        guard DesignSettings.shared.sidebarSections.sessionTree else { return false }
        return Self.checksFailing(lane, answers: pullRequests.answers)
    }

    /// Whether any of `lane`'s answers (its folder's branch's pull request, each one it opened) is
    /// open with failing checks, as its badge line reads (``item(_:)``).
    static func checksFailing(_ lane: AgentActivityLane, answers: [String: AgentPanePullRequest]) -> Bool {
        asks([lane]).contains { answers[$0].map { item($0).state == .failing } ?? false }
    }
}

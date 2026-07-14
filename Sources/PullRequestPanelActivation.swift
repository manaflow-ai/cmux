import CmuxGit

struct PullRequestPanelActivation: Equatable, Hashable {
    let input: PullRequestWorkspaceInput
    let isVisible: Bool
}

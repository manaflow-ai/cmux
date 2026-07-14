import CmuxGit
import Foundation
import SwiftUI

/// Bridges one workspace's existing git-status observation stream into the pull-request panel input.
struct PullRequestPanelWorkspaceView: View {
    @State private var input: PullRequestWorkspaceInput

    let workspace: Workspace
    let service: any PullRequestPanelServing
    let isVisible: Bool
    let onOpenURL: (URL) -> Void

    init(
        workspace: Workspace,
        service: any PullRequestPanelServing,
        isVisible: Bool,
        onOpenURL: @escaping (URL) -> Void
    ) {
        self.workspace = workspace
        self.service = service
        self.isVisible = isVisible
        self.onOpenURL = onOpenURL
        _input = State(initialValue: Self.pullRequestInput(for: workspace))
    }

    var body: some View {
        PullRequestPanelView(
            service: service,
            input: input,
            isVisible: isVisible,
            onOpenURL: onOpenURL
        )
        .task(id: workspace.id) { @MainActor in
            for await _ in workspace.sidebarObservationStream() {
                if Task.isCancelled { break }
                let updatedInput = Self.pullRequestInput(for: workspace)
                if input != updatedInput {
                    input = updatedInput
                }
            }
        }
    }

    private static func pullRequestInput(for workspace: Workspace) -> PullRequestWorkspaceInput {
        PullRequestWorkspaceInput(
            directory: workspace.presentedCurrentDirectory ?? "",
            branchHint: workspace.presentedGitBranch?.branch
        )
    }
}

import CmuxGit
import Foundation
import SwiftUI

/// Bridges one workspace's existing git-status observation stream into the pull-request panel input.
struct PullRequestPanelWorkspaceView: View {
    private struct ObservationID: Hashable {
        let workspaceID: UUID
        let isVisible: Bool
    }

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
        .task(id: ObservationID(workspaceID: workspace.id, isVisible: isVisible)) { @MainActor in
            guard isVisible else { return }
            for await _ in workspace.pullRequestSidebarObservationStream() {
                if Task.isCancelled { break }
                let updatedInput = Self.pullRequestInput(for: workspace)
                if input != updatedInput {
                    input = updatedInput
                }
            }
        }
    }

    static func pullRequestInput(for workspace: Workspace) -> PullRequestWorkspaceInput {
        guard !workspace.usesRemoteDirectoryProvenance else {
            return PullRequestWorkspaceInput(directory: "", branchHint: nil)
        }
        return PullRequestWorkspaceInput(
            directory: workspace.presentedCurrentDirectory ?? "",
            branchHint: workspace.presentedGitBranch?.branch
        )
    }
}

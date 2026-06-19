import Foundation
import Testing

@testable import CmuxSidebar

private struct NoLogLimit: SidebarLogEntryLimitProviding {
    let configuredMaxSidebarLogEntries: Int? = nil
}

@MainActor
@Suite struct WorkspaceSidebarMetadataModelProjectionTests {
    private func makeModel() -> WorkspaceSidebarMetadataModel {
        WorkspaceSidebarMetadataModel(limitProvider: NoLogLimit())
    }

    private func pr(
        _ number: Int,
        url: String,
        branch: String? = nil,
        status: SidebarPullRequestStatus = .open,
        isStale: Bool = false
    ) -> SidebarPullRequestState {
        SidebarPullRequestState(
            number: number,
            label: "PR \(number)",
            url: URL(string: url)!,
            status: status,
            branch: branch,
            isStale: isStale
        )
    }

    @Test func updatePanelGitBranchMirrorsFocusedPanelUpToWorkspace() {
        let model = makeModel()
        let focused = UUID()
        let other = UUID()

        model.updatePanelGitBranch(panelId: other, branch: "feat", isDirty: true, focusedPanelId: focused)
        // Non-focused panel does not mirror up to the workspace-level branch.
        #expect(model.gitBranch == nil)
        #expect(model.panelGitBranches[other]?.branch == "feat")

        model.updatePanelGitBranch(panelId: focused, branch: "main", isDirty: false, focusedPanelId: focused)
        #expect(model.gitBranch == SidebarGitBranchState(branch: "main", isDirty: false))
    }

    @Test func updatePanelGitBranchChangeClearsStalePullRequest() {
        let model = makeModel()
        let focused = UUID()
        model.updatePanelGitBranch(panelId: focused, branch: "feat", isDirty: false, focusedPanelId: focused)
        model.updatePanelPullRequest(
            panelId: focused,
            number: 7,
            label: "PR 7",
            url: URL(string: "https://example.com/7")!,
            status: .open,
            focusedPanelId: focused
        )
        #expect(model.panelPullRequests[focused] != nil)
        #expect(model.pullRequest?.number == 7)

        // Switching the branch on the panel drops its (now stale) pull request,
        // and because the panel is focused, the workspace-level PR clears too.
        model.updatePanelGitBranch(panelId: focused, branch: "other", isDirty: false, focusedPanelId: focused)
        #expect(model.panelPullRequests[focused] == nil)
        #expect(model.pullRequest == nil)
    }

    @Test func updatePanelPullRequestResolvesBranchFromPanelBranch() {
        let model = makeModel()
        let focused = UUID()
        model.updatePanelGitBranch(panelId: focused, branch: "feature/x", isDirty: false, focusedPanelId: focused)
        model.updatePanelPullRequest(
            panelId: focused,
            number: 3,
            label: "PR 3",
            url: URL(string: "https://example.com/3")!,
            status: .open,
            focusedPanelId: focused
        )
        // With no explicit branch, the panel's current branch is adopted.
        #expect(model.panelPullRequests[focused]?.branch == "feature/x")
    }

    @Test func clearPanelGitBranchClearsWorkspaceStateWhenFocused() {
        let model = makeModel()
        let focused = UUID()
        model.updatePanelGitBranch(panelId: focused, branch: "main", isDirty: false, focusedPanelId: focused)
        model.updatePanelPullRequest(
            panelId: focused,
            number: 1,
            label: "PR 1",
            url: URL(string: "https://example.com/1")!,
            status: .open,
            focusedPanelId: focused
        )
        model.clearPanelGitBranch(panelId: focused, focusedPanelId: focused)
        #expect(model.panelGitBranches[focused] == nil)
        #expect(model.panelPullRequests[focused] == nil)
        #expect(model.gitBranch == nil)
        #expect(model.pullRequest == nil)
    }

    @Test func clearGitMetadataClearsBranchesAndPullRequests() {
        let model = makeModel()
        let id = UUID()
        model.panelGitBranches[id] = SidebarGitBranchState(branch: "x", isDirty: false)
        model.panelPullRequests[id] = pr(2, url: "https://example.com/2")
        model.gitBranch = SidebarGitBranchState(branch: "x", isDirty: false)
        model.pullRequest = pr(2, url: "https://example.com/2")

        model.clearGitMetadata()
        #expect(model.panelGitBranches.isEmpty)
        #expect(model.panelPullRequests.isEmpty)
        #expect(model.gitBranch == nil)
        #expect(model.pullRequest == nil)
    }

    @Test func gitBranchesInDisplayOrderFollowsPanelOrder() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        model.panelGitBranches[a] = SidebarGitBranchState(branch: "alpha", isDirty: false)
        model.panelGitBranches[b] = SidebarGitBranchState(branch: "beta", isDirty: true)
        let ordered = model.gitBranchesInDisplayOrder(orderedPanelIds: [b, a])
        #expect(ordered.map(\.branch) == ["beta", "alpha"])
    }

    @Test func pullRequestsInDisplayOrderDropsBranchMismatchedPanelPRs() {
        let model = makeModel()
        let id = UUID()
        model.panelGitBranches[id] = SidebarGitBranchState(branch: "current", isDirty: false)
        // The panel's PR is tied to a branch the panel no longer reports, so it
        // is filtered out of the display projection.
        model.panelPullRequests[id] = pr(9, url: "https://example.com/9", branch: "stale")
        #expect(model.pullRequestsInDisplayOrder(orderedPanelIds: [id]).isEmpty)

        model.panelPullRequests[id] = pr(9, url: "https://example.com/9", branch: "current")
        #expect(model.pullRequestsInDisplayOrder(orderedPanelIds: [id]).map(\.number) == [9])
    }

    @Test func directoriesInDisplayOrderDeduplicatesByCanonicalKey() {
        let model = makeModel()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let resolved: [UUID: String] = [
            a: "/Users/me/project",
            b: "~/project",
            c: "/Users/me/other",
        ]
        // a and b canonicalize to the same path (given the home dir), so only the
        // first-seen form survives; order follows orderedPanelIds.
        let result = model.directoriesInDisplayOrder(
            orderedPanelIds: [a, b, c],
            resolvedPanelDirectories: resolved,
            homeDirectoryForCanonicalization: "/Users/me",
            fallbackDirectory: nil
        )
        #expect(result == ["/Users/me/project", "/Users/me/other"])
    }

    @Test func directoriesInDisplayOrderFallsBackWhenEmpty() {
        let model = makeModel()
        let result = model.directoriesInDisplayOrder(
            orderedPanelIds: [UUID()],
            resolvedPanelDirectories: [:],
            homeDirectoryForCanonicalization: "/Users/me",
            fallbackDirectory: "/tmp/fallback"
        )
        #expect(result == ["/tmp/fallback"])

        let withoutFallback = model.directoriesInDisplayOrder(
            orderedPanelIds: [UUID()],
            resolvedPanelDirectories: [:],
            homeDirectoryForCanonicalization: "/Users/me",
            fallbackDirectory: "/tmp/fallback",
            includeFallback: false
        )
        #expect(withoutFallback.isEmpty)
    }
}

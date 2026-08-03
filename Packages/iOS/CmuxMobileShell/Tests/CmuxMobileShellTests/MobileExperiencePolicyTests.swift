import Testing
@testable import CmuxMobileShell

@Suite struct MobileExperiencePolicyTests {
    @Test func fullPolicyPreservesAuthenticatedHostCapabilities() {
        let capabilities: Set<String> = [
            "terminal.render_grid.v1",
            "workspace.task_create.v1",
            "browser.stream.v1",
            "chat.artifact.v1",
        ]

        #expect(MobileExperiencePolicy.full.filteredHostCapabilities(capabilities) == capabilities)
        #expect(MobileExperiencePolicy.full.allowsBrowserStream)
        #expect(MobileExperiencePolicy.full.allowsArtifacts)
    }

    @Test func mvpPolicyPreservesCoreAgentLoopAndRemovesAdvancedSurfaces() {
        let capabilities: Set<String> = [
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.input.ordered.v1",
            "workspace.actions.v1",
            "workspace.task_create.v1",
            "notification.feed.v1",
            "browser.stream.v1",
            "browser.stream.viewport.v1",
            "workspace.changes.v1",
            "workspace.move.v1",
            "workspace.group_actions.v1",
            "workspace.groups.v1",
            "chat.artifact.v1",
            "terminal.artifact.v1",
            "iroh.artifact_lane.v1",
            "dogfood.v1",
        ]

        let filtered = MobileExperiencePolicy.mvp.filteredHostCapabilities(capabilities)

        #expect(filtered == Set([
            "events.v1",
            "terminal.render_grid.v1",
            "terminal.input.ordered.v1",
            "workspace.actions.v1",
            "workspace.task_create.v1",
            "notification.feed.v1",
        ]))
        #expect(!MobileExperiencePolicy.mvp.allowsLocalBrowser)
        #expect(!MobileExperiencePolicy.mvp.allowsBrowserStream)
        #expect(!MobileExperiencePolicy.mvp.allowsWorkspaceChanges)
        #expect(!MobileExperiencePolicy.mvp.allowsArtifacts)
        #expect(!MobileExperiencePolicy.mvp.allowsAdvancedWorkspaceManagement)
        #expect(!MobileExperiencePolicy.mvp.allowsAdvancedNetworking)
        #expect(!MobileExperiencePolicy.mvp.allowsTeamSwitching)
    }

    @MainActor
    @Test func shellPublishesOnlyEffectiveCapabilities() {
        let store = MobileShellComposite(experiencePolicy: .mvp)

        store.applySupportedHostCapabilities([
            "terminal.render_grid.v1",
            "workspace.task_create.v1",
            "browser.stream.v1",
            "workspace.changes.v1",
        ])

        #expect(store.supportedHostCapabilities == Set([
            "terminal.render_grid.v1",
            "workspace.task_create.v1",
        ]))
        #expect(!store.supportsBrowserStream)
        #expect(!store.workspaceChangesCapable)
    }
}

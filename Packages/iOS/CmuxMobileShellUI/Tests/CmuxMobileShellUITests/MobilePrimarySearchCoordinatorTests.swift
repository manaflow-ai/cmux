import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobilePrimarySearchCoordinatorTests {
    @Test func activePresentedSearchAcceptsExplicitClear() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.commitNativeSearchText(
            "query",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        coordinator.commitNativeSearchText(
            "",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }

    @Test func activePresentedSearchAcceptsNonEmptyEdit() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)

        coordinator.commitNativeSearchText(
            "release",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "release")
        #expect(coordinator.activeNativeSearchText() == "release")
    }

    @Test func deactivatingSearchRejectsPlatformCleanupWrite() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.commitNativeSearchText(
            "persisted",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        let owningTab = coordinator.commitSubmit()
        coordinator.commitNativeSearchText(
            "",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(owningTab == .workspaces)
        #expect(coordinator.workspaces == "persisted")
        #expect(coordinator.activeNativeSearchText() == "persisted")
    }

    @Test func inactiveSearchRejectsLateNativeWrite() {
        let coordinator = MobilePrimarySearchCoordinator()

        coordinator.commitNativeSearchText(
            "late",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }

    @Test func otherScopeRejectsNativeWrite() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)

        coordinator.commitNativeSearchText(
            "workspace leak",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "")
        #expect(coordinator.notifications == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }

    @Test func staleCleanupFromPriorActivationDoesNotEraseReopenedSearch() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        let firstActivation = coordinator.activationGeneration
        coordinator.commitNativeSearchText(
            "docs",
            for: .workspaces,
            activationGeneration: firstActivation
        )
        _ = coordinator.commitSubmit()

        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)
        coordinator.commitNativeSearchText(
            "alerts",
            for: .notifications,
            activationGeneration: coordinator.activationGeneration
        )
        coordinator.commitNativeSearchText(
            "",
            for: .workspaces,
            activationGeneration: firstActivation
        )
        coordinator.commitNativeSearchText(
            "",
            for: .notifications,
            activationGeneration: firstActivation
        )

        #expect(coordinator.workspaces == "docs")
        #expect(coordinator.notifications == "alerts")
        #expect(coordinator.activeNativeSearchText() == "alerts")
    }
}

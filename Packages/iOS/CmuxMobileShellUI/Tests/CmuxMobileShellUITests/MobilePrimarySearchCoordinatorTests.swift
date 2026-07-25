import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobilePrimarySearchCoordinatorTests {
    @Test func activePresentedSearchAcceptsExplicitClear() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.commitActiveNativeSearchText("query")

        coordinator.commitActiveNativeSearchText("")

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }

    @Test func activePresentedSearchAcceptsNonEmptyEdit() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)

        coordinator.commitActiveNativeSearchText("release")

        #expect(coordinator.workspaces == "release")
        #expect(coordinator.activeNativeSearchText() == "release")
    }

    @Test func deactivatingSearchRejectsPlatformCleanupWrite() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.commitActiveNativeSearchText("persisted")

        let owningTab = coordinator.commitSubmit()
        coordinator.commitActiveNativeSearchText("")

        #expect(owningTab == .workspaces)
        #expect(coordinator.workspaces == "persisted")
        #expect(coordinator.activeNativeSearchText() == "persisted")
    }

    @Test func inactiveSearchRejectsLateNativeWrite() {
        let coordinator = MobilePrimarySearchCoordinator()

        coordinator.commitActiveNativeSearchText("late")

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }

    @Test func otherScopeRejectsNativeWrite() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)

        coordinator.commitNativeSearchText("workspace leak", for: .workspaces)

        #expect(coordinator.workspaces == "")
        #expect(coordinator.notifications == "")
        #expect(coordinator.activeNativeSearchText() == "")
    }
}

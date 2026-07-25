import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobilePrimarySearchCoordinatorTests {
    @Test func activePresentedSearchAcceptsExplicitClear() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.updateNativeSearchText(
            "query",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        coordinator.updateNativeSearchText(
            "",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "")
        #expect(coordinator.searchDestinationText(for: .workspaces) == "")
    }

    @Test func activePresentedSearchKeepsNonEmptyEditInDraftUntilSubmit() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)

        coordinator.updateNativeSearchText(
            "release",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        #expect(coordinator.workspaces == "")
        #expect(coordinator.activeNativeSearchText() == "release")
        #expect(coordinator.searchDestinationText(for: .workspaces) == "release")

        #expect(coordinator.commitSubmit() == .workspaces)
        #expect(coordinator.workspaces == "release")
        #expect(coordinator.activeNativeSearchText() == "release")
    }

    @Test func dismissedSearchCommitsNativeDraft() {
        let coordinator = MobilePrimarySearchCoordinator(initialScope: .notifications)
        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)
        coordinator.updateNativeSearchText(
            "alerts",
            for: .notifications,
            activationGeneration: coordinator.activationGeneration
        )

        coordinator.setPresentation(false)

        #expect(coordinator.notifications == "alerts")
        #expect(coordinator.activeNativeSearchText() == "alerts")
        #expect(coordinator.searchDestinationText(for: .notifications) == "alerts")
    }

    @Test func nativeNotificationSearchBoundsDisplayedDraftAndCommittedQuery() {
        let coordinator = MobilePrimarySearchCoordinator(initialScope: .notifications)
        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)

        coordinator.updateNativeSearchText(
            "target" + String(repeating: "\u{0301}", count: 10_000),
            for: .notifications,
            activationGeneration: coordinator.activationGeneration
        )

        let displayedQuery = coordinator.activeNativeSearchText()
        #expect(displayedQuery.unicodeScalars.count <= MobileSearchQueryBounds.maxUnicodeScalars)
        #expect(displayedQuery.utf8.count <= MobileSearchQueryBounds.maxUTF8Bytes)
        #expect(coordinator.searchDestinationText(for: .notifications) == displayedQuery)

        #expect(coordinator.commitSubmit() == .notifications)
        #expect(coordinator.notifications == displayedQuery)
        #expect(coordinator.activeNativeSearchText() == displayedQuery)
    }

    @Test func directCommittedSearchBindingUsesSharedBounds() {
        let coordinator = MobilePrimarySearchCoordinator()

        coordinator.workspaces = "workspace" + String(repeating: "\u{0301}", count: 10_000)

        #expect(coordinator.workspaces.unicodeScalars.count <= MobileSearchQueryBounds.maxUnicodeScalars)
        #expect(coordinator.workspaces.utf8.count <= MobileSearchQueryBounds.maxUTF8Bytes)
        #expect(coordinator.activeNativeSearchText() == coordinator.workspaces)
    }

    @Test func deactivatingSearchRejectsPlatformCleanupWrite() {
        let coordinator = MobilePrimarySearchCoordinator()
        coordinator.synchronizeSelection(.workspaces)
        coordinator.setPresentation(true)
        coordinator.updateNativeSearchText(
            "persisted",
            for: .workspaces,
            activationGeneration: coordinator.activationGeneration
        )

        let owningTab = coordinator.commitSubmit()
        coordinator.updateNativeSearchText(
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

        coordinator.updateNativeSearchText(
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

        coordinator.updateNativeSearchText(
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
        coordinator.updateNativeSearchText(
            "docs",
            for: .workspaces,
            activationGeneration: firstActivation
        )
        _ = coordinator.commitSubmit()

        coordinator.synchronizeSelection(.notifications)
        coordinator.setPresentation(true)
        coordinator.updateNativeSearchText(
            "alerts",
            for: .notifications,
            activationGeneration: coordinator.activationGeneration
        )
        coordinator.updateNativeSearchText(
            "",
            for: .workspaces,
            activationGeneration: firstActivation
        )
        coordinator.updateNativeSearchText(
            "",
            for: .notifications,
            activationGeneration: firstActivation
        )

        #expect(coordinator.workspaces == "docs")
        #expect(coordinator.notifications == "")
        #expect(coordinator.activeNativeSearchText() == "alerts")
        #expect(coordinator.searchDestinationText(for: .notifications) == "alerts")
        #expect(coordinator.commitSubmit() == .notifications)
        #expect(coordinator.notifications == "alerts")
    }
}

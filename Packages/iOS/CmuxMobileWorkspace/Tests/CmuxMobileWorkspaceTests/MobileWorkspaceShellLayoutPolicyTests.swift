import SwiftUI
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileWorkspaceShellLayoutPolicyTests {
    @Test func compactHeightUsesStackWorkspaceNavigation() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                horizontalSizeClass: .regular,
                verticalSizeClass: .compact
            )
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.usesCompactStack(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular
            )
        )
    }

    @Test func regularWidthPhoneHostsSplitDestinationsInSidebar() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.hostsSplitDestinationsInSidebar(
                usesCompactStack: false,
                isPhoneIdiom: true
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.hostsSplitDestinationsInSidebar(
                usesCompactStack: false,
                isPhoneIdiom: false
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.hostsSplitDestinationsInSidebar(
                usesCompactStack: true,
                isPhoneIdiom: true
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.hostsSplitDestinationsInSidebar(
                usesCompactStack: true,
                isPhoneIdiom: false
            )
        )
    }

    @Test func splitSidebarReopensTheWayItWasLeft() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.restoredSplitColumnVisibility(sidebarWasHidden: true)
                == .detailOnly
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.restoredSplitColumnVisibility(sidebarWasHidden: false)
                == .all
        )
    }

    @Test func splitLaunchesOnTheListUntilAWorkspaceIsPicked() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.launchSplitColumnVisibility(
                sidebarWasHidden: true,
                hasSelectedWorkspace: false
            ) == .all
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.launchSplitColumnVisibility(
                sidebarWasHidden: true,
                hasSelectedWorkspace: true
            ) == .detailOnly
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.launchSplitColumnVisibility(
                sidebarWasHidden: false,
                hasSelectedWorkspace: true
            ) == .all
        )
    }

    @Test func onlyThePadSplitOpensTheFirstWorkspace() {
        #expect(
            !MobileWorkspaceShellLayoutPolicy.splitDetailFallsBackToFirstWorkspace(
                hostsSplitDestinationsInSidebar: true
            )
        )
        #expect(
            MobileWorkspaceShellLayoutPolicy.splitDetailFallsBackToFirstWorkspace(
                hostsSplitDestinationsInSidebar: false
            )
        )
    }

    @Test func phoneLaunchStartsOnTheListUnlessADeepLinkIsWaiting() {
        #expect(
            MobileWorkspaceShellLayoutPolicy.launchAwaitsWorkspacePick(
                isPhoneIdiom: true,
                hasPendingDeeplink: false
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.launchAwaitsWorkspacePick(
                isPhoneIdiom: true,
                hasPendingDeeplink: true
            )
        )
        #expect(
            !MobileWorkspaceShellLayoutPolicy.launchAwaitsWorkspacePick(
                isPhoneIdiom: false,
                hasPendingDeeplink: false
            )
        )
    }

    @Test func relaunchAfterTheSystemEndedTheAppReopensTheWorkspace() {
        typealias Policy = MobileWorkspaceShellLayoutPolicy
        #expect(Policy.launchRestoredWorkspaceID(sceneOpenWorkspaceID: "ws-1", hasPendingDeeplink: false) == "ws-1")
        // Nothing was open, or the user closed the app: start on the list.
        #expect(Policy.launchRestoredWorkspaceID(sceneOpenWorkspaceID: "", hasPendingDeeplink: false) == nil)
        // A notification tap opens its own workspace.
        #expect(Policy.launchRestoredWorkspaceID(sceneOpenWorkspaceID: "ws-1", hasPendingDeeplink: true) == nil)
    }

    @Test func edgeSwipeOpensAHiddenSidebar() {
        typealias Policy = MobileWorkspaceShellLayoutPolicy
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: false, startX: 10, sidebarWidth: 380) == .show)
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: false, startX: 120, sidebarWidth: 380) == nil)
        #expect(Policy.splitSidebarSwipeCompletes(.show, translationX: 80))
        #expect(!Policy.splitSidebarSwipeCompletes(.show, translationX: 20))
        #expect(!Policy.splitSidebarSwipeCompletes(.show, translationX: -80))
    }

    @Test func dividerSwipeClosesAShownSidebar() {
        typealias Policy = MobileWorkspaceShellLayoutPolicy
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: true, startX: 385, sidebarWidth: 380) == .hide)
        // Rows and the terminal keep their own swipes.
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: true, startX: 200, sidebarWidth: 380) == nil)
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: true, startX: 500, sidebarWidth: 380) == nil)
        #expect(Policy.splitSidebarSwipeCandidate(sidebarShown: true, startX: 10, sidebarWidth: 0) == nil)
        #expect(Policy.splitSidebarSwipeCompletes(.hide, translationX: -80))
        #expect(!Policy.splitSidebarSwipeCompletes(.hide, translationX: 80))
    }

    @Test func onlyTheSidebarColumnCountsAsShown() {
        #expect(MobileWorkspaceShellLayoutPolicy.splitSidebarIsHidden(.detailOnly))
        #expect(!MobileWorkspaceShellLayoutPolicy.splitSidebarIsHidden(.all))
        #expect(!MobileWorkspaceShellLayoutPolicy.splitSidebarIsHidden(.doubleColumn))
    }
}

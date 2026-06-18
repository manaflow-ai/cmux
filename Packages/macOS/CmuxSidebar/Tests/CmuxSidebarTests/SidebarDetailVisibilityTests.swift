import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarWorkspaceDetailVisibility")
struct SidebarWorkspaceDetailVisibilityTests {
    @Test(arguments: [
        // (showDescription, showMessage, hideAll, expectedDescription, expectedMessage)
        (true, true, false, true, true),
        (true, false, false, true, false),
        (false, true, false, false, true),
        (false, false, false, false, false),
        (true, true, true, false, false),
        (true, false, true, false, false),
        (false, true, true, false, false),
        (false, false, true, false, false),
    ])
    func resolvesEachToggleAgainstHideAll(
        showDescription: Bool,
        showMessage: Bool,
        hideAll: Bool,
        expectedDescription: Bool,
        expectedMessage: Bool
    ) {
        let visibility = SidebarWorkspaceDetailVisibility(
            showWorkspaceDescription: showDescription,
            showNotificationMessage: showMessage,
            hideAllDetails: hideAll
        )
        #expect(visibility.showsWorkspaceDescription == expectedDescription)
        #expect(visibility.showsNotificationMessage == expectedMessage)
    }
}

@Suite("SidebarWorkspaceAuxiliaryDetailVisibility")
struct SidebarWorkspaceAuxiliaryDetailVisibilityTests {
    @Test func hideAllWinsOverEveryToggle() {
        let visibility = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: true,
            showLog: true,
            showProgress: true,
            showBranchDirectory: true,
            showPullRequests: true,
            showPorts: true,
            hideAllDetails: true
        )
        #expect(visibility == .hidden)
        #expect(!visibility.showsMetadata)
        #expect(!visibility.showsPorts)
    }

    @Test func individualTogglesPassThroughWhenNotHidden() {
        let visibility = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: true,
            showLog: false,
            showProgress: true,
            showBranchDirectory: false,
            showPullRequests: true,
            showPorts: false,
            hideAllDetails: false
        )
        #expect(visibility.showsMetadata)
        #expect(!visibility.showsLog)
        #expect(visibility.showsProgress)
        #expect(!visibility.showsBranchDirectory)
        #expect(visibility.showsPullRequests)
        #expect(!visibility.showsPorts)
    }
}

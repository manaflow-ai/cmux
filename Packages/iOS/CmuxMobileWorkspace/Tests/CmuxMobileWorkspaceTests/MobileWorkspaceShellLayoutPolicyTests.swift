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
}

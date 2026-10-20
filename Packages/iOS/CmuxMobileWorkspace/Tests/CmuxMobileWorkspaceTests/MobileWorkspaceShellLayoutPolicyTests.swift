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
}

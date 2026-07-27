import SwiftUI
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileTerminalSafeAreaPolicyTests {
    @Test func expansionAccountsForIPadSidebarVisibility() {
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: true, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: false
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .splitSidebarVisible,
                hasCompactVerticalSize: true
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                includesBottom: false
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: true, bottom: false)
        )
    }

    @Test func contentInsetsProtectLandscapeCameraArea() {
        let landscapeInsets = SwiftUI.EdgeInsets(top: 0, leading: 54, bottom: 0, trailing: 21)

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: landscapeInsets
            ) == MobileTerminalContentInsets(leading: 33, trailing: 0)
        )

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59)
            ) == MobileTerminalContentInsets(leading: 0, trailing: 59)
        )

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59),
                symmetricCameraEdge: .leading
            ) == MobileTerminalContentInsets(leading: 59, trailing: 0)
        )

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59),
                symmetricCameraEdge: .none
            ) == .zero
        )

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 21, bottom: 0, trailing: 54)
            ) == MobileTerminalContentInsets(leading: 0, trailing: 33)
        )

        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8)
            ) == .zero
        )
        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .fullWidth,
                hasCompactVerticalSize: false,
                safeAreaInsets: landscapeInsets
            ) == .zero
        )
        #expect(
            MobileTerminalContentSafeAreaPolicy.horizontalInsets(
                context: .splitSidebarVisible,
                hasCompactVerticalSize: true,
                safeAreaInsets: landscapeInsets
            ) == .zero
        )
    }

    @Test func landscapeCameraEdgeFollowsWindowOrientation() {
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeLeft) == .trailing)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeRight) == .leading)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .portrait) == .trailing)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .unknown) == .trailing)
    }
}

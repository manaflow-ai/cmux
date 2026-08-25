import SwiftUI
import Testing

@testable import CmuxMobileWorkspace

@Suite struct MobileTerminalSafeAreaPolicyTests {
    @Test func compactLandscapeExpansionKeepsTheCameraEdgeProtected() {
        // A landscape phone puts the Dynamic Island / notch on one horizontal
        // edge; the terminal keeps that edge's safe-area inset and expands only
        // into the opposite one, so its content never renders under the
        // hardware.
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                cameraEdge: .trailing
            ) == MobileTerminalSafeAreaExpansionEdges(leading: true, trailing: false, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                cameraEdge: .leading
            ) == MobileTerminalSafeAreaExpansionEdges(leading: false, trailing: true, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                cameraEdge: .none
            ) == MobileTerminalSafeAreaExpansionEdges(leading: true, trailing: true, bottom: true)
        )
    }

    @Test func expansionAccountsForIPadSidebarVisibility() {
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: false,
                cameraEdge: .trailing
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .splitSidebarVisible,
                hasCompactVerticalSize: true,
                cameraEdge: .trailing
            ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
        )
        #expect(
            MobileTerminalSafeAreaExpansionPolicy.edges(
                context: .fullWidth,
                hasCompactVerticalSize: true,
                cameraEdge: .trailing,
                includesBottom: false
            ) == MobileTerminalSafeAreaExpansionEdges(leading: true, trailing: false, bottom: false)
        )
    }

    @Test func edgeSetMapsRequestedEdges() {
        #expect(
            MobileTerminalSafeAreaExpansionEdges(leading: true, trailing: false, bottom: true).edgeSet
                == [.leading, .bottom]
        )
        #expect(
            MobileTerminalSafeAreaExpansionEdges(leading: false, trailing: true, bottom: false).edgeSet
                == [.trailing]
        )
        #expect(
            MobileTerminalSafeAreaExpansionEdges(horizontal: true, bottom: true).edgeSet
                == [.horizontal, .bottom]
        )
        #expect(!MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: false).hasEdges)
    }

    @Test func landscapeCameraEdgeFollowsWindowOrientation() {
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeLeft) == .trailing)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeRight) == .leading)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .portrait) == .trailing)
        #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .unknown) == .trailing)
    }

    @Test func landscapeCameraEdgeFollowsLayoutDirection() {
        // The camera's physical side is fixed by the rotation; leading/trailing
        // flip with the layout direction.
        #expect(
            MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeLeft, isRightToLeft: true)
                == .leading
        )
        #expect(
            MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeRight, isRightToLeft: true)
                == .trailing
        )
    }
}

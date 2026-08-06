import CmuxSettings
import Testing
@testable import CmuxSidebar

@Suite("Tool sidebar layout policy")
struct ToolSidebarLayoutPolicyTests {
    @Test func leftPlacementPrecedesWorkspaceContent() {
        let policy = ToolSidebarLayoutPolicy()

        #expect(policy.placesToolSidebarBeforeWorkspace(for: .left))
        #expect(!policy.placesToolSidebarBeforeWorkspace(for: .right))
    }

    @Test func leftModeBarClearsTrafficLightsWhenWorkspaceSidebarIsHidden() {
        let policy = ToolSidebarModeBarLayoutPolicy()

        #expect(
            policy.leadingPadding(
                position: .left,
                isWorkspaceSidebarVisible: false,
                isFullScreen: false,
                trafficLightInset: 78,
                fullscreenControlsLeadingPadding: 10,
                fullscreenControlsWidth: 84
            ) == 78
        )
    }

    @Test func leftModeBarClearsFullscreenControlsWhenWorkspaceSidebarIsHidden() {
        let policy = ToolSidebarModeBarLayoutPolicy()

        #expect(
            policy.leadingPadding(
                position: .left,
                isWorkspaceSidebarVisible: false,
                isFullScreen: true,
                trafficLightInset: 78,
                fullscreenControlsLeadingPadding: 10,
                fullscreenControlsWidth: 84
            ) == 102
        )
    }

    @Test func modeBarUsesCompactPaddingWhenWindowControlsCannotOverlap() {
        let policy = ToolSidebarModeBarLayoutPolicy()

        #expect(
            policy.leadingPadding(
                position: .left,
                isWorkspaceSidebarVisible: true,
                isFullScreen: false,
                trafficLightInset: 78,
                fullscreenControlsLeadingPadding: 10,
                fullscreenControlsWidth: 84
            ) == policy.defaultLeadingPadding
        )
        #expect(
            policy.leadingPadding(
                position: .right,
                isWorkspaceSidebarVisible: false,
                isFullScreen: false,
                trafficLightInset: 78,
                fullscreenControlsLeadingPadding: 10,
                fullscreenControlsWidth: 84
            ) == policy.defaultLeadingPadding
        )
    }
}

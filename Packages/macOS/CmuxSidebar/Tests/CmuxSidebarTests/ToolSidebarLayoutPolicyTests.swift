import CmuxSettings
import Testing
@testable import CmuxSidebar

@Suite("Tool sidebar layout policy")
struct ToolSidebarLayoutPolicyTests {
    /// Verifies only left placement orders the tool sidebar before workspace content.
    @Test func leftPlacementPrecedesWorkspaceContent() {
        let policy = ToolSidebarLayoutPolicy()

        #expect(policy.placesToolSidebarBeforeWorkspace(for: .left))
        #expect(!policy.placesToolSidebarBeforeWorkspace(for: .right))
    }

    /// Verifies a left mode bar clears traffic lights without a workspace sidebar.
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

    /// Verifies a left mode bar clears custom fullscreen controls.
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

    /// Verifies compact padding is used when window controls cannot overlap the mode bar.
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

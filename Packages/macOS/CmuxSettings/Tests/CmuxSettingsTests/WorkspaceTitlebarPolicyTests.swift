import CmuxSettings
import Testing

@Suite("Workspace title bar policy")
struct WorkspaceTitlebarPolicyTests {
    @Test(arguments: [false, true], [false, true])
    func minimalModePreservesIndependentPreference(showTitlebar: Bool, minimalMode: Bool) {
        let policy = WorkspaceTitlebarPolicy(showTitlebar: showTitlebar, isMinimalMode: minimalMode)
        #expect(policy.showTitlebar == showTitlebar)
        #expect(policy.isHidden == (minimalMode || !showTitlebar))
        let standard = WorkspaceTitlebarPolicy(showTitlebar: policy.showTitlebar, isMinimalMode: false)
        #expect(standard.isHidden == !showTitlebar)
    }

    @Test(arguments: [false, true], [false, true])
    func collapsedSidebarReservesWindowControls(minimal: Bool, fullscreen: Bool) {
        let policy = WorkspaceTitlebarPolicy(showTitlebar: false, isMinimalMode: minimal)
        #expect(policy.tabBarLeadingInset(
            isSidebarVisible: false, isFullScreen: fullscreen,
            trafficLightInset: 80, fullscreenControlsWidth: 120
        ) == (fullscreen ? (minimal ? 0 : 136) : 80))
        #expect(policy.tabBarLeadingInset(
            isSidebarVisible: true, isFullScreen: fullscreen,
            trafficLightInset: 80, fullscreenControlsWidth: 120
        ) == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func visibleTitleOwnsControls(sidebar: Bool, fullscreen: Bool) {
        let policy = WorkspaceTitlebarPolicy(showTitlebar: true, isMinimalMode: false)
        #expect(policy.tabBarLeadingInset(
            isSidebarVisible: sidebar, isFullScreen: fullscreen,
            trafficLightInset: 80, fullscreenControlsWidth: 120
        ) == 0)
    }

    @Test
    func fullscreenInsetTracksMeasuredControlWidth() {
        let policy = WorkspaceTitlebarPolicy(showTitlebar: false, isMinimalMode: false)
        #expect(policy.tabBarLeadingInset(
            isSidebarVisible: false, isFullScreen: true,
            trafficLightInset: 80, fullscreenControlsWidth: 180
        ) == 196)
    }
}

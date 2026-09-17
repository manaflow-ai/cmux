#if os(iOS) && DEBUG
import Testing
@testable import CMUXMobileCore

@MainActor
struct MobileReleaseGateUIProbeTests {
    @Test func reportsOnlyMeasuredVisibleTransitions() {
        MobileReleaseGateUIProbe.reset()
        MobileReleaseGateUIProbe.record(.appRootVisible)
        MobileReleaseGateUIProbe.record(.workspaceListVisible)
        MobileReleaseGateUIProbe.record(.workspaceDetailVisible)
        MobileReleaseGateUIProbe.record(.terminalFramePresented)

        let latencies = MobileReleaseGateUIProbe.latencies()
        #expect(latencies.keys.sorted() == [
            "app_root_to_workspace_list_visible",
            "workspace_detail_to_terminal_text_visible",
            "workspace_list_to_detail_visible",
        ])
        #expect(latencies.values.allSatisfy { $0 >= 0 })
    }

    @Test func missingTerminalFrameDoesNotInventReadiness() {
        MobileReleaseGateUIProbe.reset()
        MobileReleaseGateUIProbe.record(.appRootVisible)
        MobileReleaseGateUIProbe.record(.workspaceListVisible)
        MobileReleaseGateUIProbe.record(.workspaceDetailVisible)

        let latencies = MobileReleaseGateUIProbe.latencies()
        #expect(latencies["app_root_to_workspace_list_visible"] != nil)
        #expect(latencies["workspace_list_to_detail_visible"] != nil)
        #expect(latencies["workspace_detail_to_terminal_text_visible"] == nil)
    }
}
#endif

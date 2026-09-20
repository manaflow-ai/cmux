#if DEBUG
import Testing
@testable import CMUXMobileCore

@MainActor
@Suite(.serialized)
struct MobileReleaseGateUIProbeTests {
    @Test func requiresAVisibleSelectionAndPresentedTextOnTheSelectedSurface() async throws {
        MobileReleaseGateUIProbe.reset()
        var selections = 0
        MobileReleaseGateUIProbe.closeWorkspace = {
            MobileReleaseGateUIProbe.record(.workspaceDetailHidden)
        }
        MobileReleaseGateUIProbe.registerVisibleWorkspace("workspace") {
            selections += 1
            MobileReleaseGateUIProbe.record(.workspaceSelectionTapped)
            MobileReleaseGateUIProbe.record(.workspaceDetailVisible)
            MobileReleaseGateUIProbe.recordTerminalFrame(surfaceID: "other", containsText: true)
            #expect(MobileReleaseGateUIProbe.latencies()["workspace_tap_to_terminal_text_visible"] == nil)
            MobileReleaseGateUIProbe.recordTerminalFrame(surfaceID: "terminal", containsText: false)
            #expect(MobileReleaseGateUIProbe.latencies()["workspace_tap_to_terminal_text_visible"] == nil)
            MobileReleaseGateUIProbe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
            return true
        }
        try await MobileReleaseGateUIProbe.exercise(workspaceID: "workspace", surfaceID: "terminal")
        #expect(selections == 1)
        let measured = MobileReleaseGateUIProbe.latencies()
        #expect(measured["app_launch_to_workspace_rows_visible"] != nil)
        #expect(measured["workspace_tap_to_terminal_text_visible"] != nil)
        for _ in 0..<100 {
            MobileReleaseGateUIProbe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
        }
        MobileReleaseGateUIProbe.beginLaunch(enabled: true)
        #expect(MobileReleaseGateUIProbe.latencies() == measured)
    }

    @Test func aMissingRenderedRowTimesOutInsteadOfInventingTimings() async {
        MobileReleaseGateUIProbe.reset()
        MobileReleaseGateUIProbe.record(.workspaceListVisible)
        await #expect(throws: MobileReleaseGateUIProbe.Failure.self) {
            try await MobileReleaseGateUIProbe.exercise(workspaceID: "absent", surfaceID: "terminal", timeout: .milliseconds(1))
        }
        #expect(MobileReleaseGateUIProbe.latencies().isEmpty)
    }
}
#endif

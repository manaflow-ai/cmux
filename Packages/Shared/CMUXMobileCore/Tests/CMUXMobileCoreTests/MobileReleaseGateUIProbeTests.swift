#if DEBUG
import Testing
import Foundation
@testable import CMUXMobileCore

@MainActor
@Suite(.serialized)
struct MobileReleaseGateUIProbeTests {
    @Test func includesStartupBeforeAppInitializationAndRejectsAFutureOrigin() async throws {
        let origin = DispatchTime.now().uptimeNanoseconds - 2_000_000_000
        let probe = MobileReleaseGateUIProbe(launchUptimeNanoseconds: origin)
        probe.closeWorkspace = { probe.terminalDidUnmount(surfaceID: "terminal") }
        probe.registerVisibleWorkspace("workspace") {
            probe.record(.workspaceSelectionTapped)
            probe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
            return true
        }
        try await probe.exercise(workspaceID: "workspace", surfaceID: "terminal")
        #expect(try #require(probe.latencies()["app_launch_to_workspace_rows_visible"]) >= 2)
        #expect(!MobileReleaseGateUIProbe(launchUptimeNanoseconds: .max).awaitsVisibleRows)
    }

    @Test func requiresAVisibleSelectionAndPresentedTextOnTheSelectedSurface() async throws {
        let probe = MobileReleaseGateUIProbe()
        var selections = 0
        probe.closeWorkspace = {
            probe.terminalDidUnmount(surfaceID: "terminal")
        }
        probe.registerVisibleWorkspace("workspace") {
            selections += 1
            probe.record(.workspaceSelectionTapped)
            probe.record(.workspaceDetailVisible)
            probe.recordTerminalFrame(surfaceID: "other", containsText: true)
            #expect(probe.latencies()["workspace_tap_to_terminal_text_visible"] == nil)
            probe.recordTerminalFrame(surfaceID: "terminal", containsText: false)
            #expect(probe.latencies()["workspace_tap_to_terminal_text_visible"] == nil)
            probe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
            return true
        }
        try await probe.exercise(workspaceID: "workspace", surfaceID: "terminal")
        #expect(selections == 1)
        let measured = probe.latencies()
        #expect(measured["app_launch_to_workspace_rows_visible"] != nil)
        #expect(measured["workspace_tap_to_terminal_text_visible"] != nil)
        for _ in 0..<100 {
            probe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
        }
        #expect(probe.latencies() == measured)
    }

    @Test func revealsRequestedRowsAndDoesNotInspectTextAfterCompletion() async throws {
        let probe = MobileReleaseGateUIProbe()
        probe.closeWorkspace = { probe.terminalDidUnmount(surfaceID: "terminal") }
        probe.revealWorkspace = { id in
            probe.registerVisibleWorkspace(id) {
                probe.record(.workspaceSelectionTapped)
                probe.recordTerminalFrame(surfaceID: "terminal", containsText: true)
                return true
            }
        }
        try await probe.exercise(workspaceID: "offscreen", surfaceID: "terminal")
        var inspections = 0
        func inspect() -> Bool { inspections += 1; return true }
        probe.recordTerminalFrame(surfaceID: "terminal", containsText: inspect())
        #expect(inspections == 0)
        #expect(MobileReleaseGateUIProbe().latencies().isEmpty)
    }

    @Test func aMissingRenderedRowTimesOutInsteadOfInventingTimings() async {
        let probe = MobileReleaseGateUIProbe()
        probe.record(.workspaceListVisible)
        await #expect(throws: MobileReleaseGateUIProbe.Failure.self) {
            try await probe.exercise(workspaceID: "absent", surfaceID: "terminal", timeout: .milliseconds(1))
        }
        #expect(probe.latencies().isEmpty)
    }
}
#endif

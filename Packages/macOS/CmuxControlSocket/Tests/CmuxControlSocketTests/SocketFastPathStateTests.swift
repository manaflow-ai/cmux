import CmuxControlSocket
import Foundation
import Testing

@Suite("SocketFastPathState")
struct SocketFastPathStateTests {
    @Test func firstReportPublishesAndDuplicateIsSuppressed() {
        let state = SocketFastPathState()
        let workspace = UUID()
        let panel = UUID()

        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
        #expect(!state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "commandRunning"))
        #expect(!state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "commandRunning"))
    }

    @Test func surfacesAreTrackedIndependently() {
        let state = SocketFastPathState()
        let workspace = UUID()

        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: UUID(), state: "promptIdle"))
        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: UUID(), state: "promptIdle"))
    }

    @Test func cacheResetsAtCapacityAndKeepsPublishing() {
        let state = SocketFastPathState(maxTrackedShellStates: 4)
        let workspace = UUID()
        for _ in 0..<8 {
            #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: UUID(), state: "promptIdle"))
        }
        // A duplicate after eviction republished (the legacy reset semantics):
        let panel = UUID()
        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
        #expect(!state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
    }
}

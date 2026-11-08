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

    @Test func removedPanelPublishesItsInitialStateWhenTheIDIsReused() {
        let state = SocketFastPathState()
        let workspace = UUID()
        let otherWorkspace = UUID()
        let panel = UUID()
        let otherPanel = UUID()

        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: otherPanel, state: "promptIdle"))
        #expect(state.shouldPublishShellActivity(workspaceId: otherWorkspace, panelId: panel, state: "promptIdle"))

        state.removeShellActivity(panelIds: [panel])

        #expect(state.shouldPublishShellActivity(workspaceId: workspace, panelId: panel, state: "promptIdle"))
        #expect(state.shouldPublishShellActivity(workspaceId: otherWorkspace, panelId: panel, state: "promptIdle"))
        #expect(!state.shouldPublishShellActivity(workspaceId: workspace, panelId: otherPanel, state: "promptIdle"))
    }

    @Test func replacementTerminalGenerationPublishesTheSameState() {
        let state = SocketFastPathState()
        let workspace = UUID()
        let panel = UUID()
        let oldLifecycle = UUID()
        let replacementLifecycle = UUID()

        #expect(state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: oldLifecycle,
            state: "promptIdle"
        ))
        #expect(!state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: oldLifecycle,
            state: "promptIdle"
        ))
        #expect(state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: replacementLifecycle,
            state: "promptIdle"
        ))
    }

    @Test func replacementTerminalGenerationOverwritesThePreviousDedupeSlot() {
        let state = SocketFastPathState(maxTrackedShellStates: 2)
        let workspace = UUID()
        let panel = UUID()
        let otherPanel = UUID()
        let oldLifecycle = UUID()
        let replacementLifecycle = UUID()

        #expect(state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: oldLifecycle,
            state: "promptIdle"
        ))
        #expect(state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: replacementLifecycle,
            state: "promptIdle"
        ))
        #expect(state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: otherPanel,
            state: "promptIdle"
        ))

        // Replacing one process must not consume a second cache slot for the
        // same logical surface and evict its current-generation state.
        #expect(!state.shouldPublishShellActivity(
            workspaceId: workspace,
            panelId: panel,
            terminalLifecycleID: replacementLifecycle,
            state: "promptIdle"
        ))
    }
}

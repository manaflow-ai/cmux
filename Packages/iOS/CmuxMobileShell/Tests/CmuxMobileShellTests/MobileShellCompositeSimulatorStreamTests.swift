import CMUXMobileCore
import Foundation
import Testing
import CmuxMobileShellModel
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeSimulatorStreamTests {
    /// Toolbar selection activates the panel (forcing `.starting`) before the
    /// start RPC runs. When the preflight guard fails (disconnected, missing
    /// capability, or no client), the optimistic spinner must settle back to
    /// `.idle` instead of parking the pane on "Waiting for Simulator" forever.
    @Test func preflightStartFailureSettlesActivationSpinner() async {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [Self.descriptor()])
        store.activate(panelID: "sim-1", in: "workspace-1")
        #expect(store.state(for: "sim-1")?.streamStatus == .starting)

        // Default composite state is disconnected with no remote client, so
        // the start attempt exits through the preflight guard.
        let composite = MobileShellComposite(simulatorStreamStore: store)
        await composite.startMobileSimulatorStream(panelID: "sim-1", workspaceID: "workspace-1")

        #expect(store.state(for: "sim-1")?.streamStatus == .idle)
    }

    /// A staleness fire surfaces the stall and re-requests the stream; when
    /// the restart cannot reach the Mac, the pane stays visibly stalled
    /// instead of flipping back to a live-looking frame.
    @Test func staleStreamMarksStalledAndSurvivesFailedRestart() async {
        let store = MobileSimulatorStreamStore()
        let composite = MobileShellComposite(simulatorStreamStore: store)
        // Connect before the store has panels so the reconnect path does not
        // enqueue its own restarts for this test's panel.
        composite.connectionState = .connected
        store.replaceSimulatorPanels(in: "workspace-1", with: [Self.descriptor()])
        store.activate(panelID: "sim-1", in: "workspace-1")
        store.state(for: "sim-1")?.streamStatus = .streaming
        composite.startedMobileSimulatorPanelIDs.insert("sim-1")

        composite.handleStaleMobileSimulatorStream(panelID: "sim-1")
        #expect(store.state(for: "sim-1")?.streamStatus == .stalled)

        await composite.mobileSimulatorStreamOperationsByPanel["sim-1"]?.value
        // The restart failed (no capability, no client); the stall must not
        // be masked by the attempt.
        #expect(store.state(for: "sim-1")?.streamStatus == .stalled)
    }

    /// Leaving the workspace is explicit navigation intent. The composite owns
    /// both selection and wire state, so one owner-level action must clear the
    /// selected panel and drain its active session together.
    @Test func leavingWorkspaceStopsSelectedSimulatorSession() async {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [Self.descriptor()])
        store.activate(panelID: "sim-1", in: "workspace-1")
        let composite = MobileShellComposite(simulatorStreamStore: store)
        composite.startedMobileSimulatorPanelIDs.insert("sim-1")

        composite.stopActiveMobileSimulatorStream(in: "workspace-1")

        #expect(store.activeState(in: "workspace-1") == nil)
        await composite.mobileSimulatorStreamOperationsByPanel["sim-1"]?.value
        #expect(!composite.startedMobileSimulatorPanelIDs.contains("sim-1"))
    }

    /// Route navigation carries the aggregate row id, while simulator state
    /// remains keyed by the Mac-local RPC id. The composite boundary must
    /// resolve that identity before clearing selection and wire state.
    @Test func leavingAggregatedWorkspaceStopsRemoteKeyedSimulatorSession() async {
        let rowID = MobileWorkspacePreview.ID(rawValue: "mac-a::workspace-1")
        let remoteID = MobileWorkspacePreview.ID(rawValue: "workspace-1")
        var workspace = MobileWorkspacePreview(
            id: rowID,
            name: "Workspace",
            terminals: [],
            simulators: [Self.descriptor()]
        )
        workspace.remoteWorkspaceID = remoteID
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: remoteID.rawValue, with: [Self.descriptor()])
        store.activate(panelID: "sim-1", in: remoteID.rawValue)
        let composite = MobileShellComposite(
            workspaces: [workspace],
            simulatorStreamStore: store
        )
        composite.startedMobileSimulatorPanelIDs.insert("sim-1")

        composite.stopActiveMobileSimulatorStream(in: rowID)

        #expect(store.activeState(in: remoteID.rawValue) == nil)
        await composite.mobileSimulatorStreamOperationsByPanel["sim-1"]?.value
        #expect(!composite.startedMobileSimulatorPanelIDs.contains("sim-1"))
    }

    @Test func existingSimulatorSelectionSurvivesDefaultSurfaceRefresh() {
        let workspaceID = "workspace-1"
        let selectedDescriptor = Self.descriptor(panelID: "sim-2")
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: workspaceID),
            name: "Workspace",
            terminals: [],
            simulators: [Self.descriptor(), selectedDescriptor]
        )
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: workspaceID, with: [Self.descriptor(), selectedDescriptor])
        store.activate(panelID: selectedDescriptor.panelID, in: workspaceID)
        let composite = MobileShellComposite(
            workspaces: [workspace],
            simulatorStreamStore: store
        )

        composite.selectedWorkspaceID = nil
        composite.selectedWorkspaceID = workspace.id

        #expect(store.activeState(in: workspaceID)?.id == selectedDescriptor.panelID)
    }

    @Test func staleMacSelectionFallsBackToAvailableSimulatorPanel() {
        let workspaceID = "workspace-1"
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: workspaceID),
            name: "Workspace",
            terminals: [],
            surfaces: []
        )
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: workspaceID, with: [Self.descriptor()])
        let composite = MobileShellComposite(
            workspaces: [workspace],
            simulatorStreamStore: store
        )
        composite.selectedMacSurfaceID = .init(rawValue: "stale-surface")

        composite.selectedWorkspaceID = workspace.id

        #expect(composite.selectedMacSurfaceID == nil)
        #expect(store.activeState(in: workspaceID)?.id == Self.descriptor().panelID)
    }

    @Test func focusedNonTerminalSelectionWinsWhenWorkspaceAlsoHasTerminal() {
        let focusedSurface = MobileSurfacePreview(
            id: "browser-1",
            kind: .browser,
            title: "Browser",
            isFocused: true
        )
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "zsh")
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-1"),
            name: "Workspace",
            terminals: [terminal],
            surfaces: [focusedSurface]
        )
        let composite = MobileShellComposite(workspaces: [workspace])

        #expect(workspace.focusedNonTerminalSurface?.id == focusedSurface.id)
        #expect(composite.selectedWorkspace?.focusedNonTerminalSurface?.id == focusedSurface.id)
        composite.selectedWorkspaceID = workspace.id

        #expect(composite.selectedMacSurfaceID == focusedSurface.id)
    }

    @Test func staleMacSelectionDoesNotBlockFocusedNonTerminalFallback() {
        let focusedSurface = MobileSurfacePreview(
            id: "browser-1",
            kind: .browser,
            title: "Browser",
            isFocused: true
        )
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-1"),
            name: "Workspace",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "zsh")],
            surfaces: [focusedSurface]
        )
        let composite = MobileShellComposite(workspaces: [workspace])
        composite.selectedMacSurfaceID = .init(rawValue: "removed-surface")

        composite.selectedWorkspaceID = workspace.id

        #expect(composite.selectedMacSurfaceID == focusedSurface.id)
    }

    private static func descriptor() -> MobileSimulatorPanelDescriptor {
        descriptor(panelID: "sim-1")
    }

    private static func descriptor(panelID: String) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: panelID,
            workspaceID: "workspace-1",
            title: "Simulator",
            selectedDeviceName: "iPhone 17",
            selectedDeviceState: "Booted",
            status: "streaming",
            isReady: true,
            supportsTouch: true,
            supportsKeyboard: true,
            supportsHardwareButtons: true,
            supportsRotation: true,
            ownerConnectionID: nil,
            isOwnedByCurrentConnection: nil
        )
    }
}

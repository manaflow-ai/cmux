import CMUXMobileCore
import Foundation
import Testing
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

    private static func descriptor() -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: "sim-1",
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

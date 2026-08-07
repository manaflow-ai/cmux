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

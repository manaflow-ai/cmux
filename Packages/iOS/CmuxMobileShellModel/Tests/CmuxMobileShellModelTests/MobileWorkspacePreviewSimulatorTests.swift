import CMUXMobileCore
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileWorkspacePreviewSimulatorTests {
    @Test func bootedSimulatorDetectionIsCaseInsensitiveAndStateDriven() {
        #expect(!preview(simulators: []).hasBootedSimulator)
        #expect(!preview(simulators: [descriptor(state: "Shutdown")]).hasBootedSimulator)
        #expect(!preview(simulators: [descriptor(state: nil)]).hasBootedSimulator)
        #expect(preview(simulators: [descriptor(state: "Booted")]).hasBootedSimulator)
        #expect(preview(simulators: [descriptor(state: "booted")]).hasBootedSimulator)
        #expect(preview(
            simulators: [descriptor(state: "Shutdown"), descriptor(state: "Booted")]
        ).hasBootedSimulator)
    }

    private func preview(
        simulators: [MobileSimulatorPanelDescriptor]
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: "workspace-1"),
            name: "Workspace",
            terminals: [],
            simulators: simulators
        )
    }

    private func descriptor(state: String?) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: "sim-1",
            workspaceID: "workspace-1",
            title: "Simulator",
            selectedDeviceName: "iPhone 17",
            selectedDeviceState: state,
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

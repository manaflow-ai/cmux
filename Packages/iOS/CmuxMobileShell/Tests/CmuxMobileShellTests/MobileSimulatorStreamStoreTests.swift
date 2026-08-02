import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileSimulatorStreamStoreTests {
    @Test func restartKeepsLastFrameVisibleUntilReplacementArrives() {
        let store = MobileSimulatorStreamStore()
        let descriptor = simulatorDescriptor()
        store.replaceSimulatorPanels(in: "workspace-1", with: [descriptor])
        store.activate(panelID: "sim-1", in: "workspace-1")
        let frame = MobileSimulatorFrameEvent(
            panelID: "sim-1",
            sequence: 7,
            format: .jpeg,
            pixelWidth: 390,
            pixelHeight: 844,
            displayScale: 3,
            dataBase64: "ZmFrZQ=="
        )
        let payload = try! JSONEncoder().encode(frame)

        store.receiveSimulatorFramePayload(payload)
        store.simulatorStreamWillStart(panelID: "sim-1")

        let state = store.activeState(in: "workspace-1")
        #expect(state?.latestFrame == frame)
        #expect(state?.streamStatus == .starting)
    }

    @Test func descriptorOwnedByAnotherConnectionMarksSurfaceLocked() {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [
            simulatorDescriptor(ownerConnectionID: "other", isOwnedByCurrentConnection: false),
        ])

        let state = store.state(for: "sim-1")
        #expect(state?.streamStatus == .locked)
        #expect(state?.ownerConnectionID == "other")
        #expect(state?.isOwnedByCurrentConnection == false)
    }

    private func simulatorDescriptor(
        ownerConnectionID: String? = nil,
        isOwnedByCurrentConnection: Bool = true
    ) -> MobileSimulatorPanelDescriptor {
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
            ownerConnectionID: ownerConnectionID,
            isOwnedByCurrentConnection: isOwnedByCurrentConnection
        )
    }
}

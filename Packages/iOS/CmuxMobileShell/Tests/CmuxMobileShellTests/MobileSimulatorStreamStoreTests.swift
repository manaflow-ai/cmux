import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileSimulatorStreamStoreTests {
    @Test func restartKeepsLastFrameVisibleUntilReplacementArrives() throws {
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
        let payload = try JSONEncoder().encode(frame)

        store.receiveSimulatorFramePayload(payload)
        store.simulatorStreamWillStart(panelID: "sim-1")

        let state = store.activeState(in: "workspace-1")
        #expect(state?.latestFrame == frame)
        #expect(state?.streamStatus == .starting)
    }

    @Test func frameReceiveResultIdentifiesStaleFrames() throws {
        let store = MobileSimulatorStreamStore()
        let descriptor = simulatorDescriptor()
        store.replaceSimulatorPanels(in: "workspace-1", with: [descriptor])
        store.activate(panelID: "sim-1", in: "workspace-1")
        let newest = MobileSimulatorFrameEvent(
            panelID: "sim-1",
            sequence: 9,
            format: .jpeg,
            pixelWidth: 390,
            pixelHeight: 844,
            displayScale: 3,
            dataBase64: "bmV3ZXI="
        )
        let stale = MobileSimulatorFrameEvent(
            panelID: "sim-1",
            sequence: 8,
            format: .jpeg,
            pixelWidth: 390,
            pixelHeight: 844,
            displayScale: 3,
            dataBase64: "b2xkZXI="
        )

        let newestPayload = try JSONEncoder().encode(newest)
        let stalePayload = try JSONEncoder().encode(stale)
        #expect(
            store.receiveSimulatorFramePayload(newestPayload)
                == .received(panelID: "sim-1", sequence: 9, payloadBytes: newestPayload.count)
        )
        #expect(
            store.receiveSimulatorFramePayload(stalePayload)
                == .stale(
                    panelID: "sim-1",
                    sequence: 8,
                    previousSequence: 9,
                    payloadBytes: stalePayload.count
                )
        )
        #expect(store.state(for: "sim-1")?.latestFrame == newest)
    }

    @Test func frameReceiveResultIdentifiesMalformedPayloadsAndUnknownPanels() throws {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [simulatorDescriptor()])
        let malformed = Data(#"{"panel_id":"sim-1""#.utf8)
        #expect(store.receiveSimulatorFramePayload(malformed) == .decodeFailed(payloadBytes: malformed.count))

        let unknown = MobileSimulatorFrameEvent(
            panelID: "missing",
            sequence: 3,
            format: .jpeg,
            pixelWidth: 390,
            pixelHeight: 844,
            displayScale: 3,
            dataBase64: "ZmFrZQ=="
        )
        let payload = try JSONEncoder().encode(unknown)
        #expect(
            store.receiveSimulatorFramePayload(payload)
                == .unknownPanel(panelID: "missing", sequence: 3, payloadBytes: payload.count)
        )
    }

    @Test func stateReceiveResultDescribesOwnershipTransition() throws {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [
            simulatorDescriptor(ownerConnectionID: nil, isOwnedByCurrentConnection: true),
        ])

        let payload = try JSONEncoder().encode(
            simulatorDescriptor(ownerConnectionID: "other", isOwnedByCurrentConnection: false)
        )

        #expect(
            store.receiveSimulatorStatePayload(payload)
                == .applied(
                    panelID: "sim-1",
                    ownership: .otherConnection,
                    previousOwnership: .currentConnection
                )
        )
    }

    /// A `simulator.state` event can describe a panel this phone never
    /// activated; it must not promote that panel to `.starting`.
    @Test func passiveStateUpdateDoesNotPromoteIdlePanelToStarting() throws {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [simulatorDescriptor()])

        let payload = try JSONEncoder().encode(
            simulatorDescriptor(ownerConnectionID: nil, isOwnedByCurrentConnection: nil)
        )
        store.receiveSimulatorStatePayload(payload)

        #expect(store.state(for: "sim-1")?.streamStatus == .idle)
    }

    /// Broadcast rows (state sync, workspace lists) carry nil ownership; they
    /// must not flip the owning phone to view-only or locked mid-stream.
    @Test func unknownOwnershipKeepsLastPersonalizedAnswer() {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [simulatorDescriptor()])
        store.activate(panelID: "sim-1", in: "workspace-1")
        store.simulatorStreamDidStart(
            simulatorDescriptor(ownerConnectionID: "phone", isOwnedByCurrentConnection: true)
        )
        let state = store.state(for: "sim-1")
        #expect(state?.isOwnedByCurrentConnection == true)

        store.applySimulatorDescriptor(
            simulatorDescriptor(ownerConnectionID: "phone", isOwnedByCurrentConnection: nil)
        )

        #expect(state?.isOwnedByCurrentConnection == true)
        #expect(state?.streamStatus != .locked)
    }

    /// States for panels that left every workspace (and are not active) are
    /// pruned so their retained frames do not accumulate for the app lifetime.
    @Test func replacingPanelsPrunesVanishedPanelState() {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [simulatorDescriptor()])
        #expect(store.state(for: "sim-1") != nil)

        store.replaceSimulatorPanels(in: "workspace-1", with: [])

        #expect(store.state(for: "sim-1") == nil)
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

    @Test func pendingOwnerDescriptorIsControlHandshake() {
        let store = MobileSimulatorStreamStore()
        store.replaceSimulatorPanels(in: "workspace-1", with: [
            simulatorDescriptor(ownerConnectionID: nil, isOwnedByCurrentConnection: false),
        ])

        let state = store.activate(panelID: "sim-1", in: "workspace-1")
        #expect(state?.streamStatus == .starting)
        #expect(state?.isControlHandshakePending == true)

        store.simulatorStreamDidStart(
            simulatorDescriptor(ownerConnectionID: "phone", isOwnedByCurrentConnection: true)
        )

        #expect(state?.isOwnedByCurrentConnection == true)
        #expect(state?.isControlHandshakePending == false)
    }

    private func simulatorDescriptor(
        ownerConnectionID: String? = nil,
        isOwnedByCurrentConnection: Bool? = true
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

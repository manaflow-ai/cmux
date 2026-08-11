import CMUXMobileCore
import Testing
@testable import CmuxMobileShellUI

@Suite struct SimulatorPickerMenuValueTests {
    @Test func unsupportedOrEmptyWorkspacesHideTheControl() {
        let row = SimulatorStreamPickerRow(descriptor(id: "sim-a"))

        let unsupported = SimulatorPickerMenuValue(
            supportsSimulatorStream: false,
            rows: [row],
            activePanelID: nil
        )
        let empty = SimulatorPickerMenuValue(
            supportsSimulatorStream: true,
            rows: [],
            activePanelID: nil
        )

        #expect(!unsupported.isVisible)
        #expect(unsupported.targetPanelID == nil)
        #expect(!empty.isVisible)
        #expect(empty.targetPanelID == nil)
    }

    @Test func onePanelIsTheOneTapTarget() {
        let value = SimulatorPickerMenuValue(
            supportsSimulatorStream: true,
            rows: [SimulatorStreamPickerRow(descriptor(id: "sim-a"))],
            activePanelID: nil
        )

        #expect(value.isVisible)
        #expect(value.targetPanelID == "sim-a")
    }

    @Test func activePanelReturnsThroughToolbarWhileInactiveStateUsesDeterministicFirstTarget() {
        let rows = [
            SimulatorStreamPickerRow(descriptor(id: "sim-a")),
            SimulatorStreamPickerRow(descriptor(id: "sim-b")),
        ]
        let active = SimulatorPickerMenuValue(
            supportsSimulatorStream: true,
            rows: rows,
            activePanelID: "sim-b"
        )
        let stale = SimulatorPickerMenuValue(
            supportsSimulatorStream: true,
            rows: rows,
            activePanelID: "removed"
        )

        #expect(active.activePanelID == "sim-b")
        #expect(active.targetPanelID == nil)
        #expect(stale.activePanelID == nil)
        #expect(stale.targetPanelID == "sim-a")
    }

    @Test func simulatorReturnKeepsLivePreviousTab() {
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: .terminal("term-b"),
            terminalIDs: ["term-a", "term-b"],
            browserStreamPanelIDs: ["browser-a"],
            otherSimulatorPanelIDs: []
        ) == .terminal("term-b"))
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: .browserStream("browser-a"),
            terminalIDs: ["term-a"],
            browserStreamPanelIDs: ["browser-a"],
            otherSimulatorPanelIDs: []
        ) == .browserStream("browser-a"))
    }

    @Test func simulatorReturnFallsBackWhenPreviousTabWasClosed() {
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: .terminal("removed"),
            terminalIDs: ["term-a"],
            browserStreamPanelIDs: ["browser-a"],
            otherSimulatorPanelIDs: []
        ) == .terminal("term-a"))
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: .browserStream("removed"),
            terminalIDs: [],
            browserStreamPanelIDs: ["browser-a"],
            otherSimulatorPanelIDs: []
        ) == .browserStream("browser-a"))
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: .terminal("removed"),
            terminalIDs: [],
            browserStreamPanelIDs: [],
            otherSimulatorPanelIDs: ["sim-b"]
        ) == .simulator("sim-b"))
    }

    @Test func simulatorOnlyWorkspaceHasNoReturnTarget() {
        #expect(SimulatorToolbarReturnTarget.resolve(
            preferred: nil,
            terminalIDs: [],
            browserStreamPanelIDs: [],
            otherSimulatorPanelIDs: []
        ) == nil)
    }

    private func descriptor(id: String) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: id,
            workspaceID: "workspace-1",
            title: "Simulator \(id)",
            selectedDeviceName: "iPhone \(id)",
            selectedDeviceState: "Booted",
            status: "streaming",
            isReady: true,
            supportsTouch: true,
            supportsKeyboard: true,
            supportsHardwareButtons: true,
            supportsRotation: true
        )
    }
}

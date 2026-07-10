import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator device picker labels")
struct SimulatorPaneToolbarTests {
    @Test("Every row includes state and duplicate names include runtime")
    func deviceRowsDisambiguateDuplicateNames() {
        let current = device(id: "A", runtime: "iOS 26.5", state: .booted)
        let older = device(id: "B", runtime: "iOS 18.6", state: .shutdown)
        let unique = device(id: "C", name: "iPad Pro", runtime: "iOS 26.5", state: .shutdown)
        let devices = [current, older, unique]

        #expect(SimulatorPaneToolbar.deviceRowLabel(
            current,
            among: devices,
            localizedState: "Booted"
        ) == "iPhone 17 Pro · iOS 26.5 · Booted")
        #expect(SimulatorPaneToolbar.deviceRowLabel(
            older,
            among: devices,
            localizedState: "Shut Down"
        ) == "iPhone 17 Pro · iOS 18.6 · Shut Down")
        #expect(SimulatorPaneToolbar.deviceRowLabel(
            unique,
            among: devices,
            localizedState: "Shut Down"
        ) == "iPad Pro · Shut Down")
    }

    private func device(
        id: String,
        name: String = "iPhone 17 Pro",
        runtime: String,
        state: SimulatorDeviceState
    ) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: name,
            runtimeIdentifier: runtime,
            runtimeName: runtime,
            deviceTypeIdentifier: name,
            family: name.hasPrefix("iPad") ? .iPad : .iPhone,
            state: state,
            isAvailable: true,
            lastBootedAt: nil
        )
    }
}

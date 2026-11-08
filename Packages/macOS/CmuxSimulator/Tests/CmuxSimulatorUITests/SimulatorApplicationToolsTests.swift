import CmuxSimulator
import Testing

@testable import CmuxSimulatorUI

@Suite("Simulator application picker")
struct SimulatorApplicationToolsTests {
    @Test("Application rows remain independent from later inventory updates")
    func applicationRowsAreImmutableSnapshots() {
        var applications = [application(id: "dev.cmux.one", name: "One")]
        let rows = simulatorApplicationPickerRows(applications)

        applications[0] = application(id: "dev.cmux.one", name: "Changed")

        #expect(rows == [SimulatorApplicationPickerRow(
            id: "dev.cmux.one",
            displayName: "One"
        )])
    }

    private func application(id: String, name: String) -> SimulatorInstalledApplication {
        SimulatorInstalledApplication(
            id: id,
            name: name,
            displayName: name,
            executableName: name,
            path: "/Applications/\(name).app",
            applicationType: "User"
        )
    }
}

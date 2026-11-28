import Testing
@testable import CmuxNextDesign

/// A person's machines take colors no two alike (Leo, 2026-11-28: "we can have them be delineated"),
/// the same the pages' machineColor.ts assignMachineHues gives.
struct MachineColorAutomaticTests {
    @Test func machinesWhoseNamesHashAlikeTakeTwoAccents() {
        let order = AgentPresenceColor.order
        #expect(order[AgentPresenceColor.index(forKey: "linux-box", count: order.count)] == .green)
        #expect(order[AgentPresenceColor.index(forKey: "gpu-box", count: order.count)] == .green)
        let auto = MachineColorOverrides.none.assigningAutomatic(names: ["linux-box", "GPU-Box ", "build-box"]).automatic
        #expect(auto["gpu-box"] == .green)
        #expect(auto["linux-box"] == .yellow)
        #expect(Set(auto.values).count == 3)
    }

    @Test func aPickedAccentIsTakenFirst() {
        let auto = MachineColorOverrides(["build-box": "green"]).assigningAutomatic(names: ["gpu-box", "build-box"]).automatic
        #expect(auto["build-box"] == nil)
        #expect(auto["gpu-box"] == .yellow)
    }
}

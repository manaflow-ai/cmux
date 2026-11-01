import CmuxNextCloud
import Testing

/// Agent infrastructure (fleet VMs our tooling made under a person's account) is told from the person's own
/// Cloud machines by name, the same prefixes leo-workspace `tools/cloud-vm-up` names every VM with.
@Suite struct CloudMachineAgentInfrastructureTests {
    @Test func fleetNamesAreAgentInfrastructure() {
        for name in ["fs-example-1", "fs-other-2", "fs-long-exercise-name", "sr2-probe", "lane-vm-9",
                     "fleet-probe", "FS-Example-1", "  sr2-x  "] {
            #expect(CloudMachine.isAgentInfrastructure(name: name), "\(name)")
        }
    }

    @Test func aPersonsOwnMachinesAreNot() {
        for name in ["brave-teal-otter", "calm-amber-heron", "Cloud Machine 2", "my-fs-box", "fsbox", "sr2", "", nil] as [String?] {
            #expect(!CloudMachine.isAgentInfrastructure(name: name), "\(name ?? "nil")")
        }
    }

    /// The machine's shown name decides: the display name, else the generated slug.
    @Test func theShownNameDecides() {
        #expect(CloudMachine(id: "vm-1", displayName: "fs-example-1").isAgentInfrastructure)
        #expect(!CloudMachine(id: "vm-2", displayName: "quiet-rose-finch", slug: "fs-example-2").isAgentInfrastructure)
        #expect(CloudMachine(id: "vm-3", slug: "sr2-probe").isAgentInfrastructure)
        #expect(!CloudMachine(id: "fs-vm-4").isAgentInfrastructure, "no name: the id is not a name")
    }
}

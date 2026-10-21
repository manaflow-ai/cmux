import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Machine identity: while the sidebar lists more than one machine, every workspace row marks the
/// machine it runs on, this Mac's too, by its own name (the color's key), so rows on different
/// machines tell apart. One machine: no mark.
@MainActor struct SidebarMachineMarkTests {
    private let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local, identityName: "office-mac")
    private let vm = SidebarMachine(id: MachineID("vm"), name: "gpu-box", kind: .ssh, icon: .symbol("server.rack"))

    private func options(_ machines: [SidebarMachine]) -> SidebarLayoutOptions {
        var options = SidebarLayoutOptions()
        options.machines = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        return options
    }

    @Test func eachRowMarksItsMachineByItsOwnName() throws {
        let o = options([mac, vm])
        let local = try #require(o.rowContent(SidebarWorkspace(id: WorkspaceID("a"), title: "a"), machine: nil).machine)
        #expect(local.name == "office-mac")
        #expect(local.kindIcon == .machineLocal)
        let remote = try #require(o.rowContent(SidebarWorkspace(id: WorkspaceID("b"), machineID: vm.id, title: "b"), machine: nil).machine)
        #expect(remote.name == "gpu-box")
        #expect(remote.symbol == "server.rack")
    }

    @Test func oneMachineDrawsNoMark() {
        let row = SidebarLayoutOptions().rowContent(SidebarWorkspace(id: WorkspaceID("a"), title: "a"), machine: nil)
        #expect(row.machine == nil)
    }
}

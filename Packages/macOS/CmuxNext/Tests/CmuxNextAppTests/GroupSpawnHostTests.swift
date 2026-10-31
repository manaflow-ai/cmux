import CmuxNextServer
@testable import CmuxNextApp
import Testing

/// "New Workspace" in a group runs where the group's workspaces run (remote-groups-DESIGN.md R6):
/// a group in a remote host's section keeps new work on that host instead of this Mac.
@MainActor
struct GroupSpawnHostTests {
    private final class Machine {
        let name: String
        init(_ name: String) { self.name = name }
    }

    @Test func aGroupOnARemoteHostSpawnsOnThatHost() {
        let local = Machine("local"), mini = Machine("mini")
        let host = GroupSpawnHost(memberHomes: [mini, mini], local: local).host
        #expect(host === mini)
    }

    @Test func anEmptyGroupSpawnsOnThisMac() {
        let local = Machine("local")
        #expect(GroupSpawnHost(memberHomes: [], local: local).host === local)
    }

    @Test func aGroupOfThisMacsWorkspacesSpawnsOnThisMac() {
        let local = Machine("local")
        #expect(GroupSpawnHost(memberHomes: [local], local: local).host === local)
    }

    @Test func anOldMixedGroupFallsBackToThisMac() {
        let local = Machine("local"), mini = Machine("mini"), vm = Machine("vm")
        #expect(GroupSpawnHost(memberHomes: [mini, vm], local: local).host === local)
    }
}

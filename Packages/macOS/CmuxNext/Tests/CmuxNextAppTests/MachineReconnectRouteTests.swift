import CmuxNextServer
@testable import CmuxNextApp
import Testing

/// Which reconnect a machine header's Reconnect runs (remote-groups-DESIGN.md 8.2): an SSH host its
/// own `remote.reconnect` (the header already lists it, so the shared row hides), a paired server a
/// wake of its link, a Cloud machine a retry of its link; this Mac nothing.
struct MachineReconnectRouteTests {
    @Test func eachKindReconnectsItsOwnWay() {
        #expect(MachineReconnectRoute(isLocal: false, isSSH: false, isServer: true, isCloud: false) == .wakeServer)
        #expect(MachineReconnectRoute(isLocal: false, isSSH: false, isServer: false, isCloud: true) == .retryCloud)
        #expect(MachineReconnectRoute(isLocal: false, isSSH: true, isServer: false, isCloud: false) == .ssh)
        #expect(MachineReconnectRoute(isLocal: true, isSSH: false, isServer: false, isCloud: false) == .none)
        #expect(MachineReconnectRoute(isLocal: false, isSSH: false, isServer: false, isCloud: false) == .none)
    }

    @Test func theSharedRowShowsOnlyWhereTheHeaderHasNoReconnect() {
        #expect(MachineReconnectRoute.wakeServer.showsSharedRow)
        #expect(MachineReconnectRoute.retryCloud.showsSharedRow)
        #expect(!MachineReconnectRoute.ssh.showsSharedRow)
        #expect(!MachineReconnectRoute.none.showsSharedRow)
    }
}

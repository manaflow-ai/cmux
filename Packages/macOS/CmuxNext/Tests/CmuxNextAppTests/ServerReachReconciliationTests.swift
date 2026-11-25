import CmuxNextHostedChief

import CmuxNextRemote
import Testing
@testable import CmuxNextApp

@MainActor
struct ServerReachReconciliationTests {
    private func route(_ kind: String) throws -> ServerReach.Route {
        switch kind {
        case "unix": return .unix("/private/tmp/cmux-server-reconcile.sock")
        case "overlay": return .overlay(linkSocket: "/private/tmp/cmux-server-link.sock")
        default: return try #require(ServerReach.brainRoute(serverName: "test-server"))
        }
    }

    @Test(arguments: ["unix", "overlay", "ssh"])
    func aReinstalledHostReplacesItsSessionEvenWhenTheTransportPathIsUnchanged(kind: String) throws {
        let route = try route(kind)
        let old = try ServerReach(hostID: "host_shared001", installID: "inst_before001", name: "Server", route: route)
        let current = try ServerReach(hostID: old.hostID, installID: "inst_after0001", name: old.name, route: route)
        let change = ServerReachPlan.diff(shown: [old], desired: [current])
        #expect(change.add.isEmpty && change.remove.isEmpty)
        #expect(change.reroute == [current])
    }

    @Test(arguments: ["unix", "overlay", "ssh"])
    func theSameInstallationAndRouteKeepTheirSession(kind: String) throws {
        let reach = try ServerReach(hostID: "host_shared001", installID: "inst_before001", name: "Server", route: route(kind))
        let change = ServerReachPlan.diff(shown: [reach], desired: [reach])
        #expect(change.add.isEmpty && change.remove.isEmpty && change.reroute.isEmpty)
    }
}

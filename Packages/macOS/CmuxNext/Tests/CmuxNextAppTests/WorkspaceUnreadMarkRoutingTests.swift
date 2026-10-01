@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Mark as Unread, Mark as Read, and Clear Notifications on a group reach
/// each member's own daemon, and a clear asked for while a mark is in flight
/// still goes out.
@MainActor
struct WorkspaceUnreadMarkRoutingTests {
    static func tree(_ key: String, name: String) throws -> DaemonTree {
        let json = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"\#(key)","name":"\#(name)","screens":[]}]}"#
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    @Test func groupMembersRouteToTheDaemonThatHoldsThem() throws {
        let machines = MachineRegistry(local: DaemonService())
        let host = try SSHHost(destination: SSHDestination(parsing: "dev@build-box.local"), session: "main")
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("unread-\(UUID().uuidString)"))
        let remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: paths, environment: { [:] })
        machines.add(remote)
        machines.local.store.apply(snapshot: try Self.tree("0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01", name: "here"))
        remote.daemon.store.apply(snapshot: try Self.tree("1b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c02", name: "there"))
        let here = try #require(machines.local.store.workspaces.first)
        let there = try #require(remote.daemon.store.workspaces.first)
        let elsewhere = DaemonStore()
        elsewhere.apply(snapshot: try Self.tree("2b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c03", name: "gone"))
        let gone = try #require(elsewhere.workspaces.first)

        let routes = WorkspaceUnreadMark.routes([here, there, gone], machines: machines)
        #expect(routes.map(\.workspace.name) == ["here", "there"])
        #expect(routes[0].daemon === machines.local)
        #expect(routes[1].daemon === remote.daemon)
    }

    @Test func sendDecisionKeepsAClearAskedForBeforeTheMarksEcho() {
        let start = ContinuousClock.now
        // Nothing sent yet: only a change goes out.
        #expect(WorkspaceUnreadMark.needsSend(true, false, last: nil, now: start))
        #expect(!WorkspaceUnreadMark.needsSend(false, false, last: nil, now: start))
        // A mark in flight (tree still clear): repeating it waits, a clear goes out.
        let marking: WorkspaceUnreadMark.Sent = (true, start)
        #expect(!WorkspaceUnreadMark.needsSend(true, false, last: marking, now: start + .milliseconds(500)))
        #expect(WorkspaceUnreadMark.needsSend(false, false, last: marking, now: start + .milliseconds(500)))
        // A clear in flight (tree still marked): keystrokes wait, a re-mark goes out at once.
        let clearing: WorkspaceUnreadMark.Sent = (false, start)
        #expect(!WorkspaceUnreadMark.needsSend(false, true, last: clearing, now: start + .milliseconds(500)))
        #expect(WorkspaceUnreadMark.needsSend(true, true, last: clearing, now: start + .milliseconds(500)))
        // No echo after the window: the clear is sent again.
        #expect(WorkspaceUnreadMark.needsSend(false, true, last: clearing, now: start + WorkspaceUnreadMark.echoWindow))
        // Echoed: nothing left to send.
        #expect(!WorkspaceUnreadMark.needsSend(false, false, last: clearing, now: start + .seconds(10)))
    }
}

@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing

/// Live proof subp7: a Chief that `cmux chief` started without the app opens its subagents'
/// workspaces in its own owner daemon, and the app opened later did not show them. The app
/// shows the local Chief owner daemon as a machine row on the paired-server path (decision
/// 2026-10-09, "app adopts"); a cloud read that lists no servers keeps it.
@MainActor
struct ServerReachLocalChiefTests {
    @Test func theLocalChiefOwnerShowsAsARowWithItsSubagentWorkspaces() async throws {
        let worker = ServerReachAppTests.Worker()
        let (service, machines) = ServerReachAppTests.service(worker)
        let reach = try ServerReach.localChief(homeID: "0a1b2c3d", socket: "/tmp/cmux-chief-0a1b2c3d.sock", name: "Chief")
        #expect(reach.isLocalChief)
        service.localChief = { reach }
        service.showLocalChief()
        await service.read()
        let server = try #require(machines.servers.first)
        #expect(machines.servers.count == 1, "a read with no paired servers keeps the local Chief")
        #expect(server.reach == reach)
        let key = WorkspaceKey(rawValue: "0f1e2d3c-4b5a-4968-8776-655443322110")
        server.daemon.store.noteHandshake(DaemonIdentity(registryID: "chief-owner", generation: "g"))
        server.daemon.store.apply(snapshot: DaemonTree(registryID: "chief-owner", workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "a1 · count lines"),
        ]))
        let sections = SidebarBridge.sections(machines, profile: .defaultProfile)
        let section = try #require(sections.first { $0.machine?.id.rawValue == server.machineID })
        #expect(section.machine?.name == "Chief")
        let titles = section.nodes.compactMap { node -> String? in
            if case .workspace(let workspace) = node { return workspace.title }
            return nil
        }
        #expect(titles.contains("a1 · count lines"))
        // A paired server id never passes for the local Chief.
        #expect(try !ServerReach(hostID: "host_d3f7f79203d6ec26d219", installID: "inst_584a6e8c16667f82a836",
                                 name: "box", route: .unix("/tmp/x.sock")).isLocalChief)
    }
}

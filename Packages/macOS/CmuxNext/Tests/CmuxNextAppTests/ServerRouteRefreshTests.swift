import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing
@testable import CmuxNextApp

/// A shown server's route follows this Mac's link (bead cx-ysq): when a link
/// peer for the server appears, the next read moves it to the overlay without
/// a relaunch, and a change to the link's pairing file triggers that read.
@MainActor @Suite struct ServerRouteRefreshTests {
    typealias Base = ServerReachAppTests

    final class FakeWatcher: ServerFileWatching {
        let file: URL
        let onChange: @Sendable () -> Void
        var started = false
        init(file: URL, onChange: @escaping @Sendable () -> Void) {
            self.file = file
            self.onChange = onChange
        }
        func start() { started = true }
        func stop() { started = false }
    }

    @Test func aChangedRouteIsReroutedNotForgotten() throws {
        let ssh = try ServerReach(hostID: Base.host, installID: Base.install, name: "box",
                                  route: #require(ServerReach.brainRoute(serverName: "box")))
        let overlay = try ServerReach(hostID: Base.host, installID: Base.install, name: "box", route: .overlay(linkSocket: "/tmp/l.sock"))
        let change = ServerReachPlan.diff(shown: [ssh], desired: [overlay])
        #expect(change.add.isEmpty)
        #expect(change.remove.isEmpty)
        #expect(change.reroute == [overlay])
        #expect(ServerReachPlan.diff(shown: [overlay], desired: [overlay]).reroute.isEmpty)
        #expect(ServerReachPlan.parseLinkPeersFile(Data(#"{"running":true,"peers_file":"/a/link/peers.json"}"#.utf8)) == "/a/link/peers.json")
        #expect(ServerReachPlan.parseLinkPeersFile(Data(#"{"running":true}"#.utf8)) == nil)
    }

    @Test func aNewLinkPeerMovesTheShownServerToTheOverlayOnTheFileEvent() async throws {
        let worker = Base.Worker()
        worker.chiefs = [Base.placed(Base.host)]
        worker.hosts = [Base.hostRow(Base.host, name: "box")]
        let machines = MachineRegistry(local: DaemonService())
        machines.isFeatureDisabled = { $0 == .remoteHosts }
        var link: ServerReachPlan.LinkPeers? = ServerReachPlan.LinkPeers(socket: "/tmp/l.sock", installs: [], peersFile: "/tmp/link/peers.json")
        var watchers: [FakeWatcher] = []
        let service = ServerReachService(
            machines: machines, call: { try await worker.call($0, $1) }, signedInUser: { "user_1" },
            paths: SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")),
            binary: URL(fileURLWithPath: "/usr/bin/false"), linkPeers: { link }, cli: URL(fileURLWithPath: "/usr/bin/false"),
            makeWatcher: { file, onChange in
                let watcher = FakeWatcher(file: file, onChange: onChange)
                watchers.append(watcher)
                return watcher
            })
        await service.read()
        let first = try #require(machines.servers.first)
        guard case .ssh = first.reach.route else {
            Issue.record("without a link peer the server is on SSH")
            return
        }
        let watcher = try #require(watchers.first)
        #expect(watcher.file.path == "/tmp/link/peers.json")
        #expect(watcher.started)
        // `cmux link peer add` writes the pairing file: its event re-reads.
        link?.installs = [Base.install]
        let readsBefore = worker.reads.count
        watcher.onChange()
        for _ in 0..<200 where worker.reads.count == readsBefore || machines.servers.first?.reach.route == first.reach.route {
            await Task.yield()
        }
        #expect(worker.reads.count > readsBefore, "the file event read again")
        #expect(machines.servers.count == 1)
        #expect(machines.servers.first?.reach.route == .overlay(linkSocket: "/tmp/l.sock"))
        #expect(machines.servers.first?.machineID == first.machineID)
        service.stop()
        #expect(!watcher.started)
    }
}

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

    /// The link-start gap: a link that is set up but not running still names
    /// its pairing file, so the service watches it and the registration
    /// (`link.json`), and the link starting moves the server to the overlay.
    @Test func aLinkThatStartsAfterTheReadMovesTheServerToTheOverlay() async throws {
        let show = Data(#"{"install":"inst_x","running":false,"socket":null,"peers_file":"/s/link/peers.json"}"#.utf8)
        let stopped = try #require(ServerReachPlan.linkPeers(show: show, peers: nil))
        #expect(stopped == ServerReachPlan.LinkPeers(socket: nil, installs: [], peersFile: "/s/link/peers.json", install: "inst_x"))
        #expect(stopped.watchedFiles == ["/s/link/peers.json", "/s/link.json"])
        #expect(ServerReachPlan.linkPeers(show: Data("no".utf8), peers: nil) == nil)

        let worker = Base.Worker()
        worker.chiefs = [Base.placed(Base.host)]
        worker.hosts = [Base.hostRow(Base.host, name: "box")]
        let machines = MachineRegistry(local: DaemonService())
        machines.isFeatureDisabled = { $0 == .remoteHosts }
        var link = ServerReachPlan.LinkPeers(socket: nil, installs: [Base.install], peersFile: "/tmp/link/peers.json")
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
            Issue.record("a stopped link gives no overlay route")
            return
        }
        #expect(watchers.map(\.file.path) == ["/tmp/link/peers.json", "/tmp/link.json"])
        #expect(watchers.allSatisfy { $0.started })
        let registration = try #require(watchers.last)
        // `cmux link start` writes link.json: its event re-reads.
        link.socket = "/tmp/l.sock"
        registration.onChange()
        for _ in 0..<200 where machines.servers.first?.reach.route == first.reach.route {
            await Task.yield()
        }
        #expect(machines.servers.first?.reach.route == .overlay(linkSocket: "/tmp/l.sock"))
        #expect(watchers.count == 2, "the same files keep their watches")
        service.stop()
        #expect(watchers.allSatisfy { !$0.started })
    }

    /// Bead cx-ill: this Mac is the placed server when its link install is
    /// the placed install, whatever the server's name; with a link install,
    /// a name match alone is not this Mac; without one, the name decides.
    @Test func thisMacIsMatchedByInstallIDNotName() {
        let me = ServerReachPlan.LocalServer(hostNames: ["box"], brainSocket: "/Users/me/.cmux/brains/chief/daemon/cmux.sock")
        let renamed = PairedServer(host: Base.host, name: "renamed-server", kind: "server")
        let mine = ServerReachPlan.LinkPeers(socket: "/tmp/l.sock", installs: [], install: Base.install)
        #expect(ServerReachPlan.route(for: renamed, install: Base.install, local: me, link: mine) == .unix(me.brainSocket))
        let sameName = PairedServer(host: Base.host, name: "box", kind: "server")
        let other = ServerReachPlan.LinkPeers(socket: "/tmp/l.sock", installs: [Base.install], install: "inst_bbbbbbbbbbbbbbbbbbbb")
        #expect(ServerReachPlan.route(for: sameName, install: Base.install, local: me, link: other) == .overlay(linkSocket: "/tmp/l.sock"))
        #expect(ServerReachPlan.route(for: sameName, install: Base.install, local: me, link: nil) == .unix(me.brainSocket))
    }
}

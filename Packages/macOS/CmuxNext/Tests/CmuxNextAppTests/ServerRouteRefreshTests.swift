import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation
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

    /// A service whose link is read from `link` and whose watchers land in `watchers`.
    private static func service(_ worker: Base.Worker, _ machines: MachineRegistry, link: @escaping @MainActor () -> ServerReachPlan.LinkPeers?,
                                setup: String? = nil, watchers: @escaping @MainActor (FakeWatcher) -> Void) -> ServerReachService {
        ServerReachService(
            machines: machines, call: { try await worker.call($0, $1) }, signedInUser: { "user_1" },
            paths: SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")),
            binary: URL(fileURLWithPath: "/usr/bin/false"), linkPeers: link, cli: URL(fileURLWithPath: "/usr/bin/false"),
            linkSetupFile: setup,
            makeWatcher: { file, onChange in
                let watcher = FakeWatcher(file: file, onChange: onChange)
                watchers(watcher)
                return watcher
            })
    }

    /// An established connection that ends (here EOF) reports its end, so
    /// the server reach can re-resolve the route at once.
    @Test(.timeLimit(.minutes(1))) func anEndedConnectionReportsItsEnd() async throws {
        let server = try ScriptedDaemonSocket(handler: RemoteMachineCompatTests.daemon { RemoteMachineCompatTests.required })
        let service = DaemonService(machineID: "server-host_test")
        let (ends, ended) = AsyncStream.makeStream(of: Void.self)
        let path = server.path
        service.start(remote: { path }, onEnd: { ended.yield() })
        defer { service.shutdownConnection() }
        for await state in Observations({ service.store.connectionState }) {
            if case .connected = state { break }
        }
        server.stop()
        var iterator = ends.makeAsyncIterator()
        #expect(await iterator.next() != nil, "the end of the connection was reported")
    }

    /// The overlay ended and the link is gone (`link show` says not
    /// running): the server falls back to SSH without a file event.
    @Test func anEndedOverlayReResolvesTheRoute() async throws {
        let worker = Base.Worker()
        worker.chiefs = [Base.placed(Base.host)]
        worker.hosts = [Base.hostRow(Base.host, name: "box")]
        let machines = MachineRegistry(local: DaemonService())
        machines.isFeatureDisabled = { $0 == .remoteHosts }
        var link = ServerReachPlan.LinkPeers(socket: "/tmp/l.sock", installs: [Base.install], peersFile: "/tmp/link/peers.json")
        let service = Self.service(worker, machines, link: { link }, watchers: { _ in })
        await service.read()
        let first = try #require(machines.servers.first)
        #expect(first.reach.route == .overlay(linkSocket: "/tmp/l.sock"))
        link.socket = nil
        first.onOverlayEnded?()
        for _ in 0..<200 where machines.servers.first?.reach.route == first.reach.route {
            await Task.yield()
        }
        guard case .ssh? = machines.servers.first?.reach.route else {
            Issue.record("a dead link must fall back to SSH: \(String(describing: machines.servers.first?.reach.route))")
            return
        }
        service.stop()
    }

    /// No link yet (`link show` fails): the service watches where `cmux link
    /// init` writes, and the init re-reads and arms the link's own watches.
    @Test func aLinkInitializedLaterIsNoticedByEvent() async throws {
        #expect(ServerReachPlan.defaultLinkSetupFile(environment: [:], home: "/Users/me")
            == "/Users/me/Library/Application Support/cmux-tui/sessions/link/config.json")
        #expect(ServerReachPlan.defaultLinkSetupFile(environment: ["CMUX_TUI_STATE_DIR": "/s"], home: "/Users/me") == "/s/link/config.json")
        let worker = Base.Worker()
        worker.chiefs = [Base.placed(Base.host)]
        worker.hosts = [Base.hostRow(Base.host, name: "box")]
        let machines = MachineRegistry(local: DaemonService())
        machines.isFeatureDisabled = { $0 == .remoteHosts }
        var link: ServerReachPlan.LinkPeers?
        var watchers: [FakeWatcher] = []
        let service = Self.service(worker, machines, link: { link }, setup: "/s/link/config.json", watchers: { watchers.append($0) })
        await service.read()
        let setup = try #require(watchers.first)
        #expect(watchers.map(\.file.path) == ["/s/link/config.json"])
        #expect(setup.started)
        link = ServerReachPlan.LinkPeers(socket: nil, installs: [], peersFile: "/s/link/peers.json")
        setup.onChange()
        for _ in 0..<200 where watchers.count == 1 {
            await Task.yield()
        }
        #expect(!setup.started, "the setup watch is replaced")
        #expect(watchers.dropFirst().map(\.file.path) == ["/s/link/peers.json", "/s/link.json"])
        service.stop()
    }
}

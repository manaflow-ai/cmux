import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// The `server` reach in the app (plans/cmux-next/server-reach.md): which
/// paired servers show, their sidebar section with the brain's workspaces
/// under the server's name, and removal when the pairing goes away. The
/// API Worker is a scripted `call`; no SSH and no network.
@MainActor @Suite struct ServerReachAppTests {
    static let host = "host_e641389e5f37d1e37fb5"
    static let otherHost = "host_aaaaaaaaaaaaaaaaaaaa"
    static let install = "inst_7dadf279a00e51dc4a1f"
    static let brainSession = "55555555-6666-4777-8888-999999999999"

    static func chief(_ id: String, placedOn host: String?, isDefault: Bool = false) -> CloudChief {
        CloudChief(id: id, displayName: id, isDefault: isDefault, mainConversation: nil, rev: 1,
                   brainPlace: host.map { CloudChief.BrainPlace(host: $0, install: install) })
    }

    /// Scripted API Worker: `chief.list` and `team.hosts.list` from `state`.
    final class Worker {
        var chiefs: [[String: Any]] = []
        var hosts: [[String: Any]] = []
        var failReads = false
        /// Replies `ok` with a value that lacks `hosts` / `chiefs`.
        var malformed = false
        var reads: [String] = []

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            let op = body["op"] as? String ?? ""
            reads.append(op)
            if failReads { throw FeedServiceError.owner(code: "owner.unreachable", message: "offline") }
            if malformed { return ["ok": true, "value": ["team": "team_x"]] }
            switch op {
            case "chief.list": return ["ok": true, "value": ["chiefs": chiefs]]
            case "team.hosts.list": return ["ok": true, "value": ["team": "team_x", "hosts": hosts, "next_cursor": NSNull()]]
            default: throw FeedServiceError.owner(code: "validation.invalid", message: op)
            }
        }
    }

    static func placed(_ host: String, chief: String = "agent_A") -> [String: Any] {
        ["id": chief, "rev": 1, "display_name": "Chief", "is_default": true, "brain_place": ["host": host, "install": install]]
    }

    static func hostRow(_ id: String, name: String, kind: String = "server") -> [String: Any] {
        ["id": id, "name": name, "kind": kind, "platform": "macos"]
    }

    /// A registry with remote hosts "turned off" so added servers never dial.
    static func service(_ worker: Worker, local: ServerReachPlan.LocalServer? = nil) -> (ServerReachService, MachineRegistry) {
        let machines = MachineRegistry(local: DaemonService())
        machines.isFeatureDisabled = { $0 == .remoteHosts }
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("server-reach-\(UUID().uuidString)"))
        let service = ServerReachService(machines: machines, call: { try await worker.call($0, $1) }, signedInUser: { "user_1" },
                                         paths: paths, binary: URL(fileURLWithPath: "/usr/bin/false"), local: { local })
        return (service, machines)
    }

    // MARK: Plan

    @Test func onlyServersThatRunAChiefAndAreStillPairedShow() {
        let hosts = [PairedServer(host: Self.host, name: "cmux-lawrences-Mac-mini", kind: "server"),
                     PairedServer(host: Self.otherHost, name: "laptop", kind: "device")]
        let plan = ServerReachPlan.make(chiefs: [Self.chief("a", placedOn: Self.host, isDefault: true),
                                                 Self.chief("b", placedOn: Self.host),
                                                 Self.chief("c", placedOn: nil),
                                                 Self.chief("d", placedOn: Self.otherHost),
                                                 Self.chief("e", placedOn: "host_revokedrevokedrevoked")],
                                        hosts: hosts, local: nil)
        #expect(plan.desired.map(\.hostID) == [Self.host])
        let reach = plan.desired[0]
        #expect(reach.name == "cmux-lawrences-Mac-mini")
        #expect(reach.installID == Self.install)
        guard case .ssh(let ssh) = reach.route else { Issue.record("expected the ssh route"); return }
        #expect(ssh.remoteMuxSocket == ServerReach.brainSocket)
    }

    @Test func aServerThatIsThisMacUsesTheBrainSocketDirectly() {
        let local = ServerReachPlan.LocalServer(hostNames: ["cmuxs-Mac-mini"], brainSocket: "/Users/cmux/.cmux/brains/chief/daemon/cmux.sock")
        let plan = ServerReachPlan.make(chiefs: [Self.chief("a", placedOn: Self.host)],
                                        hosts: [PairedServer(host: Self.host, name: "cmuxs-Mac-mini", kind: "server")], local: local)
        #expect(plan.desired.first?.route == .unix(local.brainSocket))
    }

    /// A Mac whose DHCP host name ("mac") differs from the LocalHostName the
    /// server was paired under is still this Mac: any of its names matches.
    @Test func thisMacMatchesUnderAnyOfItsNames() {
        let socket = "/Users/cmux/.cmux/brains/chief/daemon/cmux.sock"
        let local = ServerReachPlan.LocalServer(hostNames: ["mac", "cmuxs-MacBook-Pro-2", "cmux’s MacBook Pro (2)"], brainSocket: socket)
        let host = PairedServer(host: Self.host, name: "cmuxs-MacBook-Pro-2", kind: "server")
        #expect(ServerReachPlan.route(for: host, local: local) == .unix(socket))
        let other = PairedServer(host: Self.otherHost, name: "build-box", kind: "server")
        guard case .ssh = ServerReachPlan.route(for: other, local: local) else {
            Issue.record("a server with another name must not be this Mac")
            return
        }
    }

    /// Overlay route (server-reach.md 7 step 1): a server whose install this
    /// Mac's link has as a paired peer is dialed through the link; this Mac's
    /// own brain still wins, and an unpaired server stays on SSH.
    @Test func aServerPairedWithThisMacsLinkUsesTheOverlay() throws {
        let socket = "/tmp/cmux-501/link.sock"
        let link = ServerReachPlan.LinkPeers(socket: socket, installs: [Self.install])
        let host = PairedServer(host: Self.host, name: "build-box", kind: "server")
        #expect(ServerReachPlan.route(for: host, install: Self.install, local: nil, link: link) == .overlay(linkSocket: socket))
        guard case .ssh = ServerReachPlan.route(for: host, install: "inst_bbbbbbbbbbbbbbbbbbbb", local: nil, link: link) else {
            Issue.record("an install the link does not know must not use the overlay")
            return
        }
        let me = ServerReachPlan.LocalServer(hostNames: ["build-box"], brainSocket: "/Users/me/.cmux/brains/chief/daemon/cmux.sock")
        #expect(ServerReachPlan.route(for: host, install: Self.install, local: me, link: link) == .unix(me.brainSocket))
        let reach = try ServerReach(hostID: Self.host, installID: Self.install, name: "build-box", route: .overlay(linkSocket: socket))
        #expect(ServerReach(transportFields: reach.transportFields) == reach)
        #expect(reach.dialArguments(linkSocket: socket)
            == ["link", "dial", "--host", Self.install, "--service", "owner_session", "--socket", socket])
        #expect(ServerReachPlan.parseLinkShow(Data(#"{"running":true,"socket":"/tmp/l.sock","install":"inst_x"}"#.utf8)) == "/tmp/l.sock")
        #expect(ServerReachPlan.parseLinkShow(Data(#"{"running":false,"socket":null}"#.utf8)) == nil)
        #expect(ServerReachPlan.parsePeerList(Data(#"{"peers":[{"install":"inst_a"},{"install":"inst_b"}]}"#.utf8)) == ["inst_a", "inst_b"])
    }

    @Test func diffKeepsShownServersAndRemovesRevokedOnes() throws {
        let a = try ServerReach(hostID: Self.host, installID: Self.install, name: "a", route: .unix("/tmp/a.sock"))
        let b = try ServerReach(hostID: Self.otherHost, installID: Self.install, name: "b", route: .unix("/tmp/b.sock"))
        let moved = try ServerReach(hostID: Self.host, installID: Self.install, name: "a", route: .unix("/tmp/elsewhere.sock"))
        let change = ServerReachPlan.diff(shown: [a, b], desired: [moved])
        #expect(change.add.isEmpty)
        #expect(change.remove == [b.machineID])
    }

    // MARK: Service, registry and sidebar

    @Test func aPlacedChiefsServerJoinsTheSidebarWithItsWorkspacesUnderItsName() async throws {
        let worker = Worker()
        worker.chiefs = [Self.placed(Self.host)]
        worker.hosts = [Self.hostRow(Self.host, name: "cmux-lawrences-Mac-mini")]
        let (service, machines) = Self.service(worker)
        await service.read()
        let server = try #require(machines.servers.first)
        #expect(machines.servers.count == 1)
        #expect(server.machineID == "server-\(Self.host)")
        #expect(machines.remoteDaemons.contains { $0 === server.daemon })
        #expect(machines.anyDaemon(machine: server.machineID) === server.daemon)
        #expect(machines.machineName(server.machineID) == "cmux-lawrences-Mac-mini")
        // The brain opened a subagent workspace in its own session.
        let key = WorkspaceKey(rawValue: "0f1e2d3c-4b5a-4968-8776-655443322110")
        server.daemon.store.noteHandshake(DaemonIdentity(registryID: Self.brainSession, generation: "brain"))
        server.daemon.store.apply(snapshot: DaemonTree(registryID: Self.brainSession, workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: key, name: "sub-1 · fix the build"),
        ]))
        let sections = SidebarBridge.sections(machines, profile: .defaultProfile)
        let section = try #require(sections.first { $0.machine?.id.rawValue == server.machineID })
        #expect(section.machine?.kind == .server)
        #expect(section.machine?.name == "cmux-lawrences-Mac-mini")
        let titles = section.nodes.compactMap { node -> String? in
            if case .workspace(let workspace) = node { return workspace.title }
            return nil
        }
        #expect(titles.contains("sub-1 · fix the build"))
        #expect(ControlSessions.transport(server.daemon, machines: machines) == "server")
        let fields = try #require(SSHService.fields(ServerReachService.transport(server)))
        #expect(ServerReach(transportFields: fields) == server.reach)
    }

    @Test func revokingThePairingRemovesTheServerAndAFailedReadChangesNothing() async throws {
        let worker = Worker()
        worker.chiefs = [Self.placed(Self.host)]
        worker.hosts = [Self.hostRow(Self.host, name: "box")]
        let (service, machines) = Self.service(worker)
        await service.read()
        #expect(machines.servers.count == 1)
        worker.failReads = true
        await service.read()
        #expect(machines.servers.count == 1, "an offline Worker must not drop a shown server")
        worker.failReads = false
        worker.malformed = true
        await service.read()
        #expect(machines.servers.count == 1, "a reply without hosts or chiefs is not an empty directory")
        worker.malformed = false
        worker.hosts = []  // server.revoke deletes the host
        await service.read()
        #expect(machines.servers.isEmpty)
        #expect(machines.daemons.count == 1)
    }

    @Test func movingTheChiefOffAServerRemovesIt() async {
        let worker = Worker()
        worker.chiefs = [Self.placed(Self.host)]
        worker.hosts = [Self.hostRow(Self.host, name: "box"), Self.hostRow(Self.otherHost, name: "box2")]
        let (service, machines) = Self.service(worker)
        await service.read()
        worker.chiefs = [Self.placed(Self.otherHost)]
        await service.read()
        #expect(machines.servers.map(\.reach.hostID) == [Self.otherHost])
    }

    @Test func anUnreachableServerShowsUnreachableNeverInstallRequired() throws {
        let reach = try ServerReach(hostID: Self.host, installID: Self.install, name: "box",
                                    route: #require(ServerReach.brainRoute(serverName: "box")))
        let session = ServerMachineSession(reach: reach, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                           paths: SSHPaths(root: FileManager.default.temporaryDirectory), environment: { [:] },
                                           localIdentity: { nil })
        let machines = MachineRegistry(local: DaemonService())
        let link = try #require(session.link)
        for (status, expected) in [(SSHConnectionMachine.Status.unreachable("No route to host"), SidebarMachine.Status.unreachable),
                                   (.needsInstall(.missing), .unreachable), (.offline, .offline),
                                   (.authFailed("Permission denied"), .authFailed)] {
            link.linkStatus = status
            #expect(session.sidebarMachine(machines: machines).status == expected, "\(status)")
        }
        #expect(link.machineID == session.machineID)
        #expect(session.daemon.machineID == session.machineID)
    }
}

import CmuxNextDaemonService
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Exercise the real server reach coordinator. All socket paths are private,
/// absent fixture paths; no host service, SSH process or user daemon is started.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ServerReachAdmissionTests {
    @MainActor final class Harness {
        let root = URL(fileURLWithPath: "/private/tmp/cn-server-admit-" + String(UUID().uuidString.prefix(8)))
        let home = DaemonService()
        let machines: MachineRegistry
        var user: String? = "fixture-user"
        var fail = false
        var install = "inst_before001"
        var listed = true
        var calls: [String] = []
        var removed: [DaemonService] = []
        lazy var service = ServerReachService(machines: machines, mainWork: MainWorkScheduler(budget: MainFrameBudget()), call: { [unowned self] path, body in
            #expect(path == "v1/read")
            let op = body["op"] as? String ?? ""
            calls.append(op)
            if fail { throw FeedServiceError.signedOut }
            switch op {
            case "chief.list":
                let chiefs: [[String: Any]] = listed ? [["id": "chief-fixture", "rev": 1,
                    "brain_place": ["host": "host_shared001", "install": install]]] : []
                return ["value": ["chiefs": chiefs]]
            case "team.hosts.list":
                let hosts: [[String: Any]] = listed ? [["id": "host_shared001", "name": "Fixture Server", "kind": "server"]] : []
                return ["value": ["hosts": hosts]]
            default: throw FeedServiceError.badReply
            }
        }, signedInUser: { [unowned self] in user }, paths: .init(root: root.appendingPathComponent("links")),
            binary: nil, local: { [unowned self] in .init(hostNames: ["fixture-server"], brainSocket: socket) })

        init() {
            machines = MachineRegistry(local: home)
            home.store.noteHandshake(DaemonIdentity(generation: "home-only"))
            machines.onDaemonRemoved = { [weak self] in self?.removed.append($0) }
        }

        var socket: String { root.appendingPathComponent("brain.sock").path }
        func reach(_ install: String = "inst_before001") throws -> ServerReach {
            try .init(hostID: "host_shared001", installID: install, name: "Fixture Server", route: .unix(socket))
        }
        func record(_ reach: ServerReach, connect: Bool = true) -> SessionRecord {
            let fields = reach.transportFields.merging(["connect": connect ? "true" : "false"]) { $1 }
            return .init(id: "remembered-session", transport: .object(fields.mapValues(JSONValue.string)), migrated: true)
        }
        func restore(connect: Bool = true) throws -> ServerMachineSession {
            service.restore([record(try reach(), connect: connect)])
            return try #require(machines.servers.first)
        }
        func stop() {
            service.stop()
            for server in machines.servers { _ = machines.removeServer(server.machineID) }
        }
    }

    @Test func savedRoutesKeepOfflineReconnectAndTemporaryPolicyReadmission() throws {
        let h = Harness(); defer { h.stop() }
        let saved = try h.restore()
        #expect(saved.daemon.isStarting && saved.autoConnect)
        h.service.applyPolicy(disabled: true)
        #expect(!saved.daemon.isStarting)
        h.service.applyPolicy(disabled: false)
        #expect(saved.daemon.isStarting, "a temporary policy block is not permanent retirement")
    }

    @Test func aFreshDirectoryReadRetiresTheOldInstallationAndAdmitsItsReplacement() async throws {
        let h = Harness(); defer { h.stop() }
        let old = try h.restore()
        h.install = "inst_after0001"
        await h.service.read()
        let current = try #require(h.machines.servers.first)
        #expect(current !== old && current.reach.installID == h.install)
        #expect(current.reach.route == old.reach.route)
        #expect(h.removed.contains { $0 === old.daemon })
        #expect(current.daemon.isStarting)
        old.connect(); old.wake()
        #expect(!old.daemon.isStarting, "a retained reference cannot reconnect the previous installation")
        old.close()
        #expect(h.calls == ["chief.list", "team.hosts.list"])
    }

    @Test func anUnavailableDirectoryKeepsAnAlreadyAuthenticatedSavedRoute() async throws {
        let h = Harness(); defer { h.stop() }
        let saved = try h.restore()
        h.fail = true
        await h.service.read()
        #expect(h.machines.servers.first === saved)
        #expect(saved.daemon.isStarting)
    }

    @Test func freshAdmissionPreservesAnExplicitDisconnectPreference() async throws {
        let h = Harness(); defer { h.stop() }
        let saved = try h.restore(connect: false)
        await h.service.read()
        #expect(h.machines.servers.first === saved && !saved.autoConnect)
        #expect(!saved.daemon.isStarting)
    }

    @Test func aCurrentDirectoryReadKeepsTheExistingSavedConnection() async throws {
        let h = Harness(); defer { h.stop() }
        let saved = try h.restore()
        #expect(saved.daemon.isStarting)
        await h.service.read()
        #expect(h.machines.servers.first === saved)
        #expect(saved.daemon.isStarting)
    }

    @Test func oldRegistryEchoesCannotReplaceAnAdmittedCurrentInstallation() async throws {
        let h = Harness(); defer { h.stop() }
        h.install = "inst_after0001"
        await h.service.read()
        let current = try #require(h.machines.servers.first)
        h.service.restore([h.record(try h.reach())])
        #expect(h.machines.servers.first === current && current.reach.installID == h.install)
    }

    @Test func removingAPairingRetiresCapturedReconnectReferences() async throws {
        let h = Harness(); defer { h.stop() }
        await h.service.read()
        let old = try #require(h.machines.servers.first)
        h.listed = false
        await h.service.read()
        #expect(h.machines.servers.isEmpty)
        old.connect(); old.wake()
        #expect(!old.daemon.isStarting)
        old.close()
    }

    @Test func aFailedRefreshKeepsAnAlreadyAdmittedConnection() async throws {
        let h = Harness(); defer { h.stop() }
        await h.service.read()
        let admitted = try #require(h.machines.servers.first)
        h.fail = true
        await h.service.read()
        #expect(h.machines.servers.first === admitted && admitted.daemon.isStarting)
    }
}

import CmuxNextDaemonService
@testable import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWakeups
import AppKit
import Foundation
import Observation
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
        /// The app's scheduler, run by hand: `rig.frame()` runs the posted flushes.
        let rig = MainDeadlineRig()
        var mainWork: MainWorkScheduler { rig.deadlines.work }
        /// The service's own notice center: a post here is the app becoming active.
        let center = NotificationCenter()
        lazy var appEvents = AppEvents(center: center)
        let account = Account()
        var user: String? {
            get { account.user }
            set { account.user = newValue }
        }
        var fail = false
        var install = "inst_before001"
        var listed = true
        var calls: [String] = []
        var removed: [DaemonService] = []
        lazy var service = ServerReachService(machines: machines, mainWork: mainWork, appEvents: appEvents, call: { [weak self] path, body in
            // Weak: a read the service started (start, activation) may run after the test ended.
            guard let self else { throw FeedServiceError.signedOut }
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
        }, signedInUser: { [weak self] in self?.user }, paths: .init(root: root.appendingPathComponent("links")),
            binary: nil, local: { [weak self] in
                self.map { ServerReachPlan.LocalServer(hostNames: ["fixture-server"], brainSocket: $0.socket) }
            })

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

    /// The signed-in user, observable as the app's CloudAuth is.
    @MainActor @Observable final class Account {
        var user: String? = "fixture-user"
    }

    // MARK: Scheduler sweep (p06-scheduler-313): service observations and the activation notice

    @Test func signingOutClosesTheServersOnTheFlushNotInTheChangesTurn() throws {
        let h = Harness(); defer { h.stop() }
        h.service.start()
        let saved = try h.restore()
        h.user = nil
        #expect(h.machines.servers.first === saved, "the sign-out applied in its own turn, before the scheduler ran it")
        h.rig.frame()
        // A service observation: the servers close whether or not any window shows them.
        #expect(h.machines.servers.isEmpty, "a sign-out left the account's servers in the sidebar")
    }

    @Test func theActivationNoticeReadsTheDirectory() async throws {
        let h = Harness(); defer { h.stop() }
        h.user = nil
        h.service.start()
        // Signed in again; that change's flush waits for a frame this test never runs.
        h.user = "fixture-user"
        #expect(h.calls.isEmpty)
        h.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        while h.calls.count < 2 { await Task.yield() }
        #expect(Array(h.calls.prefix(2)) == ["chief.list", "team.hosts.list"], "the activation read \(h.calls)")
    }

    @Test func stopEndsTheWatchesAndTheActivationSubscription() throws {
        let h = Harness(); defer { h.stop() }
        h.service.start()
        _ = try h.restore()
        h.service.stop()
        #expect(!h.appEvents.isObserving(NSApplication.didBecomeActiveNotification), "stop kept the activation observer")
        h.user = nil
        h.rig.frame()
        // A sign-out the service still followed would have removed the (closed) server.
        #expect(!h.machines.servers.isEmpty, "a stopped service still followed the sign-out")
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

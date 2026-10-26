@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import os
import Testing

/// The automatic update of a Cloud machine on the Cloud app server's link (``CloudLinkSession``)
/// whose daemon the app refused, through the real connection path: a ``CloudMachineSession`` with
/// an app link connects to a stand-in daemon that answers `identify` with an older protocol, so
/// the handshake refuses it and leaves no connection. The update must still reach that daemon's
/// socket, and the machine connects again afterwards. Only the link resolver (the app server's
/// `cloud.machine.connect`), the daemon and `cmux link machine update` are stand-ins.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudMachineUpdateAppLinkTests {
    @Test func aRefusedDaemonOnAnAppLinkIsUpdatedAndConnectedAgain() async throws {
        let fixture = try AppLinkFixture()
        defer { fixture.remove() }
        let resolver = CountingLinkResolver(socket: fixture.daemonSocket.path)
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-app", displayName: "App VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: "vm-app"), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let machines = MachineRegistry(local: DaemonService())
        // Before the connect: a failed first attempt would ask the app link for its socket again,
        // which ends the link.
        try await fixture.waitUntil { FileManager.default.fileExists(atPath: fixture.daemonSocket.path) }
        session.connect()

        try await fixture.waitUntil { machines.compatibility(of: session.daemon)?.level == .incompatible }
        #expect(session.daemon.connection == nil, "the refused daemon left no connection")
        #expect(session.appLink != nil && session.link == nil)
        #expect(CloudMachineUpdates.daemon(of: session, machines: machines) == CloudMachineUpdateTarget.Daemon(build: nil, level: .incompatible))
        #expect(await resolver.opens == 1)

        let cli = CloudMoveCLI(binary: fixture.cli, timeout: .seconds(20))
        let source = CloudMachineUpdates.source(session, machines: machines, cli: cli,
                                                logger: Logger(subsystem: "com.cmuxterm.app.next.tests", category: "cloud.machine-update"))
        let target = CloudMachineUpdateTarget(machineID: "vm-app", displayName: "App VM", source: source)
        let outcome = await target.update(to: try #require(DaemonBuildCommit("abc123def456")), whileBusy: true)

        #expect(outcome == .updated(build: "abc123def456"))
        #expect(fixture.cliCalls == [["link", "machine", "update", "--socket", fixture.daemonSocket.path, "--to-bundled"]])
        // The machine connects again, to the daemon the update left there.
        try await fixture.waitUntil { fixture.identifies >= 2 }
        #expect(await resolver.opens == 2, "a fresh connect of the app link")
    }
}

/// When an update's handshakes are offered (``HandshakeFollower``) and how an app link connects
/// after one (``CloudMachineSession/afterUpdate(restarted:linkEnded:connected:connecting:)``).
@MainActor @Suite
struct CloudMachineUpdateFollowTests {
    typealias Handshake = CloudMachineUpdates.Handshake

    private func offers(_ follower: inout HandshakeFollower, enabled: Bool = true, made: Bool = true,
                        _ handshakes: (String, String?)...) -> [String] {
        let due = follower.due(CloudMachineUpdates.Snapshot(enabled: enabled, handshakes: handshakes.map { Handshake(machineID: $0.0, key: $0.1) }))
        if made { due.forEach { follower.offered($0) } }
        return due.map(\.machineID)
    }

    /// A machine refused while the toggles are off is offered once they turn on, and once only.
    @Test func aRefusalWhileOffIsOfferedOnceTheTogglesAreOn() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, enabled: false, ("vm-1", "refused")) == [])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "refused")) == [], "the same handshake once")
    }

    /// Offered, then the toggles go off (the policy may drop what it queued) and on again: every
    /// live handshake is offered once more.
    @Test func anOfferIsMadeAgainAfterTheTogglesGoOffAndOn() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, enabled: false, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == [])
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, ("vm-1", "refused"), ("vm-2", "c2:7:1")) == [])
    }

    /// An offer not made (no `cmux` client yet) leaves the handshake due.
    @Test func anOfferNotMadeStaysDue() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, made: false, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
    }

    /// A machine with no handshake, or gone from the list, forgets its last: a second refusal (the
    /// same key) after a drop is new, and so is a machine that comes back.
    @Test func aHandshakeAfterADropIsNew() {
        var follower = HandshakeFollower()
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", nil)) == [])
        #expect(offers(&follower, ("vm-1", "refused")) == ["vm-1"])
        #expect(offers(&follower, ("vm-1", "c1:42:1"), ("vm-2", "c2:7:1")) == ["vm-1", "vm-2"])
        #expect(offers(&follower, ("vm-2", "c2:7:1")) == [])
        #expect(offers(&follower, ("vm-1", "c1:42:1"), ("vm-2", "c2:7:1")) == ["vm-1"], "a machine gone and back")
    }

    /// An update that may have restarted the daemon connects afresh, also when the app still holds
    /// the old daemon's connection because its drop has not arrived yet: the old ticket goes, so
    /// that late drop changes nothing. One that restarted nothing leaves a healthy connection alone.
    @Test func anUpdateThatRestartedTheDaemonConnectsAfreshBeforeTheOldDropArrives() {
        typealias Session = CloudMachineSession
        #expect(Session.afterUpdate(restarted: true, linkEnded: false, connected: true, connecting: false) == .connect(dropTicket: true),
                "the CLI answered before the old connection's drop")
        #expect(Session.afterUpdate(restarted: true, linkEnded: true, connected: false, connecting: false) == .connect(dropTicket: true))
        #expect(Session.afterUpdate(restarted: true, linkEnded: false, connected: false, connecting: true) == .connectAfterHop)
        #expect(Session.afterUpdate(restarted: false, linkEnded: false, connected: true, connecting: false) == .connect(dropTicket: false))
        #expect(Session.afterUpdate(restarted: false, linkEnded: false, connected: false, connecting: false) == .connect(dropTicket: true),
                "a refused daemon's link")

        #expect(CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: true, updated: true, build: "abc123def456")))
        #expect(!CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: true, updated: false, build: "abc123def456")))
        #expect(!CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_busy")))
        #expect(!CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: false, errorCode: "machine_unreachable")))
        #expect(CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_rolled_back")))
        #expect(CloudMachineUpdateTarget.mayHaveRestarted(CloudMoveCLI.Answer(ok: false, errorCode: "machine_update_unresolved")))
        #expect(CloudMachineUpdateTarget.mayHaveRestarted(nil), "the CLI gave no answer")
    }
}

/// The app server's `cloud.machine.connect` as a ``CloudLinkResolver``: every connect answers the
/// stand-in daemon's socket.
private actor CountingLinkResolver: CloudLinkResolver {
    let socket: String
    private(set) var opens = 0

    init(socket: String) {
        self.socket = socket
    }

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        opens += 1
        return CloudLinkSocket(key: key, path: socket, generation: 1)
    }

    func close(_ key: CloudLinkKey) async {}
}

/// A temporary directory with a stand-in machine daemon (a Python Unix socket server that answers
/// `identify` with protocol 11 and logs each one) and a stand-in `cmux` that logs its arguments and
/// answers `link machine update` as updated.
@MainActor
private final class AppLinkFixture {
    let root: URL
    let daemonSocket: URL
    let cli: URL
    private let daemon = Process()

    init() throws {
        // Short: a Unix socket path holds at most 104 bytes.
        root = URL(fileURLWithPath: "/private/tmp/cn-upd-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        daemonSocket = root.appendingPathComponent("d.sock")
        cli = root.appendingPathComponent("cmux")
        let server = #"""
        import json, socket, sys, threading
        path, log = sys.argv[1], sys.argv[2]
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(8)
        def serve(conn):
            with conn, conn.makefile('rwb') as stream:
                for line in stream:
                    frame = json.loads(line)
                    data = {}
                    if frame.get('cmd') == 'identify':
                        with open(log, 'a') as out:
                            out.write('identify\n')
                        data = {'app': 'cmux-tui', 'protocol': 11, 'version': '0.0.1', 'generation': 'old-boot', 'capabilities': []}
                    stream.write((json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}) + '\n').encode())
                    stream.flush()
        while True:
            conn, _ = server.accept()
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
        """#
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        daemon.arguments = ["-u", "-c", server, daemonSocket.path, root.appendingPathComponent("identify.log").path]
        daemon.standardInput = FileHandle.nullDevice
        try daemon.run()
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(root.appendingPathComponent("cli.log").path)'
            echo '{"ok":true,"updated":true,"build":"abc123def456","previous_build":"0000old"}'

            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    /// Each `cmux` run's arguments.
    var cliCalls: [[String]] {
        let text = (try? String(contentsOf: root.appendingPathComponent("cli.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
    }

    /// The `identify` requests the stand-in daemon answered: one per connection.
    var identifies: Int {
        let text = (try? String(contentsOf: root.appendingPathComponent("identify.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    /// Waits up to 20 seconds for `condition`, which the app's connection makes true.
    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }

    /// Ends the stand-in daemon this fixture started and removes its directory.
    func remove() {
        if daemon.isRunning { daemon.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
}

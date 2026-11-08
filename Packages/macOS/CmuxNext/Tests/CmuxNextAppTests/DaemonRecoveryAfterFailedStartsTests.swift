import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Restore fuzz finding h2 (chaos diskfull, STATUS 3149; build feat d1f0e63691a0): the app's cmux-tui
/// daemon dies (SIGKILL) while the disk under its state is full. The app shows "disconnected", and its
/// reconnect's `server ensure` fails while the disk stays full. When the disk has space again the app
/// does not start a new daemon by itself (none within 60 s), and in 2 of 3 runs `debug.daemon` says
/// `offers_restart: false`, so nothing on screen gets the person out. Restart cmux-tui recovers in 1 s.
///
/// The rule: the app degrades with a visible state and recovers. While no daemon runs and no restart
/// runs, Restart cmux-tui is offered with the reason the start failed; and the app keeps starting the
/// daemon by itself with backoff (on the injected clock), so it reconnects once a start works.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonRecoveryAfterFailedStartsTests {
    /// A count the endpoint provider and the event pump share with the test.
    private nonisolated final class Counter: Sendable {
        private let value = Mutex(0)
        var current: Int { value.withLock { $0 } }
        /// Adds one and returns the count before it.
        @discardableResult func increment() -> Int {
            value.withLock { count in
                defer { count += 1 }
                return count
            }
        }
    }

    /// `server ensure` on a full disk that is not a stuck owner: the owner could not be spawned.
    private nonisolated static let diskFullEnsure =
        #"{"code":"server.spawn_failed","message":"could not start the session owner: No space left on device (os error 28)","details":{},"retryable":false}"#

    /// Test-harness poll for a step that runs on another task (a main-actor hop, the event pump).
    /// The 5 s limit is only a failure deadline; no product timing depends on it.
    private static func eventually(_ done: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await done()
    }

    private static func temporaryRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Restart is offered, with the reason

    /// A stand-in `cmux-tui` (never a real daemon): no owner runs, and a plain `server ensure` fails
    /// the way a start on a full disk fails. Each call's arguments go to `calls.log`.
    private static func standInScript(log: URL) -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        case " $* " in
        *" --version "*) echo 'cmux-tui 0.1.0'; exit 0 ;;
        *" server status "*) exit 1 ;;
        *" server ensure "*) echo '\(diskFullEnsure)' >&2; exit 3 ;;
        esac
        exit 64
        """
    }

    @MainActor private final class NoActions: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// The daemon is gone and the reconnect's `server ensure` (the launcher's endpoint, as
    /// `DaemonConnection` runs it after EOF) fails on the full disk. No daemon runs and no restart
    /// runs, so Restart cmux-tui must be offered, and the reason must reach what the person reads.
    @Test func restartIsOfferedWithTheReasonWhenTheReconnectsEnsureFailsOnAFullDisk() async throws {
        let root = try Self.temporaryRoot("cn-diskfull-offer")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let binary = root.appendingPathComponent("cmux-tui")
        try Self.standInScript(log: log).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-diskfull-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state"), binaryIsBundled: true),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
        let service = DaemonService()
        // Only the person's Restart here: the automatic restart is DaemonAutoRestartTests'.
        service.recovery.restartsUnresponsiveOwner = { false }
        service.recovery.attach(launcher, wake: service.retryWake)

        do {
            _ = try await launcher.endpointProvider()
            Issue.record("the stand-in's ensure started an owner")
        } catch {}
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try #require(text.contains("server ensure"), "the reconnect's endpoint ran no `server ensure`: \(text)")

        let offered = await Self.eventually { service.recovery.offersRestart }
        #expect(!service.recovery.isRestarting)
        #expect(offered, """
            the reconnect's ensure failed (no daemon runs, no restart runs) and Restart cmux-tui is not offered: \
            offersRestart is true only for a stuck-owner failure (DaemonLauncher.isStuckOwnerFailure)
            """)

        #if DEBUG
        // What the fuzz reads (`debug.daemon`), and what a surface shows the person.
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: NoActions())
        router.register([service.debugControlMethod { [] }])
        let answer = try await router.handle(ControlRequest(id: "1", method: "debug.daemon", params: [:])).get()
        let recovery = try #require(answer.objectValue?["recovery"]?.objectValue, "debug.daemon has no recovery: \(answer)")
        #expect(recovery["offers_restart"] == CmuxNextSettings.JSONValue.bool(true), "debug.daemon recovery: \(recovery)")
        // The typed reason, not English text (REVIEW.md).
        #expect(recovery["start_failure"] == CmuxNextSettings.JSONValue.string("disk_full"),
                "the start's failure reason (a full disk) is not exposed with the offer: \(recovery)")
        #endif
    }

    // MARK: - The app keeps starting the daemon by itself

    /// A stand-in daemon behind a bridge (never a real daemon): it answers the handshake as cmux-tui
    /// with `generation`, and exits unanswered on `die` (the daemon is killed: the app reads EOF).
    private nonisolated static let fakeDaemon = #"""
    import json, sys
    generation, die = sys.argv[1], sys.argv[2]
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == die:
            sys.exit(0)
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': generation, 'pid': 4242, 'capabilities': []}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    private nonisolated static func daemon(socket: String, generation: String) -> DaemonEndpoint {
        // `env -u SWIFT_BACKTRACE`: the test wrapper's variable makes python3 print a line before the script.
        let bridge = DaemonBridge(executable: "/usr/bin/env", arguments: [
            "-u", "SWIFT_BACKTRACE", "/usr/bin/python3", "-u", "-c", fakeDaemon, generation, ListWorkspacesRequest.command,
        ])
        return DaemonEndpoint(socketPath: socket, bridge: bridge)
    }

    /// The daemon dies, then its restarts (`server ensure` through the endpoint) fail as long as the
    /// disk stays full: here 30 of them, about 15 minutes at the reconnect's 30 s cap. The next start
    /// works. The connection is the app's local one (`DaemonService.localConfiguration`) on a manual
    /// clock: each time the reconnect sleeps on its backoff the test moves the clock past it. The
    /// reconnect must never park waiting for an event (a disk with space again sends none) and must
    /// reach the daemon once a start works.
    @Test func theAppKeepsStartingTheDaemonWithBackoffAfterAFullDiskAndReconnectsOnceAStartWorks() async throws {
        let root = try Self.temporaryRoot("cn-diskfull-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("cmux.sock").path
        let clock = ManualClock()
        let wake = RetryWake(owner: "DaemonRecoveryAfterFailedStartsTests")
        var configuration = DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false,
                                                             installKey: nil, echoesPlacementShift: false, retryWake: wake)
        configuration.requiredCapabilities = []
        let failing = 30
        let starts = Counter()
        let connection = DaemonConnection(configuration: configuration, clock: clock) {
            let start = starts.increment()
            if start == 0 { return Self.daemon(socket: socket, generation: "before-full-disk") }
            if start <= failing { throw DaemonError.launchFailed("exit 3: \(Self.diskFullEnsure)") }
            return Self.daemon(socket: socket, generation: "after-full-disk")
        }
        let drops = Counter()
        // task-owner: drains the connection's events for the test; cancelled at its end.
        let pump = Task {
            for try await envelope in connection.events {
                if case .disconnected = envelope.event { drops.increment() }
            }
        }
        defer { pump.cancel() }

        let first = try await connection.start()
        #expect(first.generation.rawValue == "before-full-disk")
        // The kill: the stand-in exits on this request without answering, and the connection reads EOF.
        _ = try? await connection.request(ListWorkspacesRequest())
        let dropped = await Self.eventually { drops.current >= 1 }
        try #require(dropped, "the connection never saw the daemon's EOF")

        var parkedForAnEvent = false
        var reconnected = false
        var elapsed = Duration.zero
        for _ in 0..<(failing + 10) {
            do {
                try await clock.waitForSleeper(within: .seconds(5))
            } catch {
                parkedForAnEvent = true
                break
            }
            // A connection that is up arms only its health timer.
            if await connection.identity?.generation.rawValue == "after-full-disk" {
                reconnected = true
                break
            }
            clock.advance(by: .seconds(30))
            elapsed += .seconds(30)
        }
        let failedStarts = max(0, starts.current - 1)

        #expect(!parkedForAnEvent, """
            after \(failedStarts) failed starts (a full disk) the reconnect armed no timer and waits for an event \
            only; a disk that has space again sends none, so the app never starts the daemon by itself
            """)
        #expect(reconnected, "the app did not reconnect after \(failedStarts) failed starts then one that works")
        #expect(starts.current > failing + 1, "the app stopped starting the daemon after \(failedStarts) failed starts")
        #expect(elapsed <= .seconds(30) * (failing + 1), "the starts were spaced past the 30 s cap: \(elapsed) in total")
        await connection.closeAndWait()
    }
}

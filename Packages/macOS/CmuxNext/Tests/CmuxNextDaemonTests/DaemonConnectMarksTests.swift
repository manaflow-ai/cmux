import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The launch's daemon connect milestones (`daemon.connect_started`, `spawned`, `identified`,
/// `snapshot_received`) go out once each, only while the startup connect runs, and `identified` and
/// `snapshot_received` only for the connection the startup attaches.
@Suite(.timeLimit(.minutes(1)))
struct DaemonConnectMarksTests {
    /// The milestones a sink got, in order, with their times.
    final class Received: Sendable {
        private let state = Mutex<[(name: String, date: Date)]>([])

        var names: [String] { state.withLock { $0.map(\.name) } }

        var dates: [Date] { state.withLock { $0.map(\.date) } }

        func append(_ name: String, _ date: Date) { state.withLock { $0.append((name, date)) } }
    }

    /// A connection that is never started: the marks only compare its identity.
    static func idleConnection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cn-connect-marks.sock"))
    }

    @Test("A launch-wide milestone goes to the sink once, however often it is marked")
    func eachMilestoneOnce() {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        for _ in 0..<3 {
            marks.mark(.connectStarted)
            marks.mark(.spawned)
        }
        #expect(received.names == ["daemon.connect_started", "daemon.spawned"])
    }

    @Test("Marks from many threads at once still send a milestone once")
    func concurrentMarksSendOnce() async {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { marks.mark(.spawned) } }
        }
        #expect(received.names == ["daemon.spawned"])
    }

    @Test("Every milestone has its own ring code in the launch timings")
    func milestonesAreTimingSteps() {
        for milestone in DaemonConnectMarks.Milestone.allCases {
            #expect(DaemonLaunchTimings.Step.traceCode(of: milestone.rawValue) != 0, "\(milestone.rawValue)")
        }
    }

    @Test("An ensure that started a daemon marks spawned once, over reconnects")
    func startedEnsureMarksSpawnedOnce() async throws {
        let standIn = try StandIn(ensureStatus: "started")
        defer { standIn.remove() }
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        let provider = marks.endpointProvider(of: standIn.launcher)
        _ = try await provider()
        _ = try await provider()
        #expect(received.names == ["daemon.spawned"])
    }

    @Test("An ensure that found a running owner marks no spawn")
    func runningOwnerMarksNoSpawn() async throws {
        let standIn = try StandIn(ensureStatus: "running")
        defer { standIn.remove() }
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        _ = try await marks.endpointProvider(of: standIn.launcher)()
        #expect(received.names.isEmpty)
    }

    /// A launch after the app alone ended (`kill -9`) finds the daemon running and reattaches to it
    /// (`DaemonService.launchAttach`); one whose attempt started a daemon did not.
    @Test("startedDaemon says whether a startup attempt started the daemon")
    func startedDaemonFollowsTheSpawn() async throws {
        let running = try StandIn(ensureStatus: "running")
        defer { running.remove() }
        let warm = DaemonConnectMarks()
        _ = try await warm.endpointProvider(of: running.launcher)()
        #expect(!warm.startedDaemon, "the launch found the daemon running")
        let started = try StandIn(ensureStatus: "started")
        defer { started.remove() }
        let cold = DaemonConnectMarks()
        _ = try await cold.endpointProvider(of: started.launcher)()
        #expect(cold.startedDaemon)
    }

    @Test("A spawn after the startup connect closed does not make it a started daemon")
    func spawnAfterCloseIsNotStarted() {
        let marks = DaemonConnectMarks()
        marks.close()
        marks.mark(.spawned)
        #expect(!marks.startedDaemon)
    }

    @Test("A warm launch's later respawn, through the same provider, marks no spawn once the startup attached")
    func respawnAfterAttachMarksNoSpawn() async throws {
        let standIn = try StandIn(ensureStatus: "running")
        defer { standIn.remove() }
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        let provider = marks.endpointProvider(of: standIn.launcher)
        _ = try await provider()
        await marks.attach(Self.idleConnection())
        // The daemon crashed; the connection's reconnect re-runs ensure, which starts a new one.
        try standIn.setEnsureStatus("started")
        _ = try await provider()
        #expect(received.names == ["daemon.identified"])
    }

    @Test("A respawn after the startup gave up marks nothing")
    func respawnAfterCloseMarksNothing() async throws {
        let standIn = try StandIn(ensureStatus: "running")
        defer { standIn.remove() }
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        let provider = marks.endpointProvider(of: standIn.launcher)
        _ = try await provider()
        marks.close()
        try standIn.setEnsureStatus("started")
        _ = try await provider()
        marks.mark(.identified, of: Self.idleConnection())
        #expect(received.names.isEmpty)
    }

    @Test("An attached connection's kept marks go out with the times they happened")
    func attachSendsKeptMarksWithTheirTimes() async {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        let connection = Self.idleConnection()
        marks.mark(.identified, of: connection)
        marks.mark(.snapshotReceived, of: connection)
        marks.mark(.identified, of: connection)
        #expect(received.names.isEmpty, "kept until the startup attaches the connection")
        let beforeAttach = Date()
        await marks.attach(connection)
        #expect(received.names == ["daemon.identified", "daemon.snapshot_received"])
        #expect(received.dates.allSatisfy { $0 <= beforeAttach })
        marks.mark(.snapshotReceived, of: connection)
        #expect(received.names.count == 2)
    }

    @Test("A handed-off connection's marks never go out; its successor's do")
    func handedOffConnectionMarksNothing() async {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0, $1) }
        let exiting = Self.idleConnection()
        marks.mark(.identified, of: exiting)
        marks.mark(.snapshotReceived, of: exiting)
        let successor = Self.idleConnection()
        let beforeAttach = Date()
        await marks.attach(successor)
        #expect(received.names == ["daemon.identified"])
        #expect(received.dates.allSatisfy { $0 >= beforeAttach }, "the successor's handshake, not the exiting daemon's")
        marks.mark(.snapshotReceived, of: exiting)
        #expect(received.names == ["daemon.identified"])
        marks.mark(.snapshotReceived, of: successor)
        #expect(received.names == ["daemon.identified", "daemon.snapshot_received"])
    }

    @Test("A failed first connect, then a retry that spawns and attaches: each milestone once")
    func failedPrestartThenRetryMarksOnce() async throws {
        let failing = try StandIn(ensureStatus: nil)
        defer { failing.remove() }
        let received = Received()
        let prestart = DaemonPrestart(launcher: failing.launcher,
                                      configuration: DaemonConnection.Configuration(terminalEnvironment: nil),
                                      marks: DaemonConnectMarks { received.append($0, $1) })
        #expect(received.names == ["daemon.connect_started"], "marked when main begins the attempt")
        guard case .failure = await prestart.outcome() else {
            Issue.record("the stand-in's ensure fails, so the attempt must fail")
            return
        }
        #expect(received.names == ["daemon.connect_started"])
        // The service's retry connects through the same marks' provider and attaches its connection.
        let starting = try StandIn(ensureStatus: "started")
        defer { starting.remove() }
        let provider = prestart.marks.endpointProvider(of: starting.launcher)
        _ = try await provider()
        let retry = Self.idleConnection()
        await prestart.marks.attach(retry)
        prestart.marks.mark(.snapshotReceived, of: retry)
        _ = try await provider()
        prestart.marks.mark(.connectStarted)
        #expect(received.names == ["daemon.connect_started", "daemon.spawned", "daemon.identified",
                                   "daemon.snapshot_received"])
    }

    /// A stand-in `cmux-tui`: `server status` finds no owner and `server ensure` answers the current ensure status
    /// (`started` or `running`), or fails when it is nil. Never a real daemon.
    struct StandIn {
        let root: URL
        let launcher: DaemonLauncher
        private let statusFile: URL

        init(ensureStatus: String?) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cn-connect-marks-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            root = directory
            let statusFile = directory.appendingPathComponent("ensure-status")
            self.statusFile = statusFile
            let session = "cn-connect-marks-\(UUID().uuidString.prefix(8).lowercased())"
            let socket = directory.appendingPathComponent("owner.sock").path
            let script = """
            #!/bin/sh
            case " $* " in
            *" server status "*) exit 1 ;;
            *" server ensure "*)
              status=$(cat '\(statusFile.path)')
              if [ "$status" = fail ]; then
                echo '{"code":"server.spawn_failed","message":"could not start the session owner"}' >&2
                exit 3
              fi
              printf '{"status":"%s","session":"\(session)","socket":"\(socket)","pid":4242,"generation":"g-1"}\\n' "$status"
              exit 0 ;;
            esac
            exit 64
            """
            let binary = directory.appendingPathComponent("cmux-tui")
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            launcher = DaemonLauncher(
                work: BackgroundWork(label: "test.daemon-connect-marks"),
                configuration: .init(binary: binary, session: session, stateDirectory: directory.appendingPathComponent("state")),
                environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })
            try setEnsureStatus(ensureStatus)
        }

        /// What the next `server ensure` answers (nil: it fails).
        func setEnsureStatus(_ status: String?) throws {
            try (status ?? "fail").write(to: statusFile, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The whole first connect against the same-tree daemon, as `DaemonService.start` runs it: the startup attaches its
/// connection, so all four milestones go out, once each and in launch order.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct DaemonConnectMarksLiveTests {
    static func launcher(_ id: some StringProtocol, root: URL) throws -> DaemonLauncher {
        let binary = try #require(RealBinary.url)
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: ProcessInfo.processInfo.environment,
                                                                    overrides: [:])
        return DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-connect-marks-live"),
            configuration: .init(binary: binary, session: "cnd-cm-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
    }

    @Test("A cold first connect marks connect_started, spawned, identified, snapshot_received once each")
    func coldPrestartMarksEveryMilestone() async throws {
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-cm-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let received = DaemonConnectMarksTests.Received()
        let prestart = DaemonPrestart(launcher: try Self.launcher(id, root: root),
                                      configuration: BranchDaemonHarness.configuration(),
                                      marks: DaemonConnectMarks { received.append($0, $1) })
        let (connection, _) = try await prestart.outcome().get()
        await prestart.marks.attach(connection)
        // The store's first snapshot takes the prefetched one, which marks its arrival before it returns.
        _ = try await connection.snapshot()
        await BranchDaemonHarness.shutDown(connection)
        #expect(received.names == ["daemon.connect_started", "daemon.spawned", "daemon.identified",
                                   "daemon.snapshot_received"])
    }

    @Test("A failed first connect and a retry that spawns the daemon mark each milestone once")
    func failedFirstThenRetryMarksEveryMilestone() async throws {
        let failing = try DaemonConnectMarksTests.StandIn(ensureStatus: nil)
        defer { failing.remove() }
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-cm-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = try Self.launcher(id, root: root)
        let received = DaemonConnectMarksTests.Received()
        let prestart = DaemonPrestart(launcher: failing.launcher, configuration: BranchDaemonHarness.configuration(),
                                      marks: DaemonConnectMarks { received.append($0, $1) })
        let marks = prestart.marks
        let connected = await DaemonStartup.shared.connect(
            policy: RetryPolicy(initial: .milliseconds(1), maximum: .milliseconds(1), timedRetries: 3),
            first: { await prestart.outcome() },
            makeConnection: {
                DaemonConnection(configuration: BranchDaemonHarness.configuration(),
                                 endpointProvider: marks.endpointProvider(of: launcher))
            },
            onFailure: { _ in })
        let (connection, _) = try #require(connected)
        await marks.attach(connection)
        _ = try await connection.snapshot()
        await BranchDaemonHarness.shutDown(connection)
        #expect(received.names == ["daemon.connect_started", "daemon.spawned", "daemon.identified",
                                   "daemon.snapshot_received"])
    }
}

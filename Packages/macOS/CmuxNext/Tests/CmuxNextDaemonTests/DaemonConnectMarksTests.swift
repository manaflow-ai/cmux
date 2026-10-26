import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p08-startup-066: the launch's daemon connect milestones (`daemon.connect_started`, `spawned`, `identified`,
/// `snapshot_received`) go out once each, from the first connect `main` begins (``DaemonPrestart``), and
/// `daemon.spawned` only when its `server ensure` started a daemon.
@Suite(.timeLimit(.minutes(1)))
struct DaemonConnectMarksTests {
    /// The milestone names a sink got, in order.
    final class Received: Sendable {
        private let state = Mutex<[String]>([])

        var names: [String] { state.withLock { $0 } }

        func append(_ name: String) { state.withLock { $0.append(name) } }
    }

    @Test("Each milestone goes to the sink once, however often it is marked")
    func eachMilestoneOnce() {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0) }
        for _ in 0..<3 {
            for milestone in DaemonConnectMarks.Milestone.allCases { marks.mark(milestone) }
        }
        #expect(received.names == ["daemon.connect_started", "daemon.spawned", "daemon.identified",
                                   "daemon.snapshot_received"])
    }

    @Test("Marks from many threads at once still send a milestone once")
    func concurrentMarksSendOnce() async {
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { marks.mark(.identified) } }
        }
        #expect(received.names == ["daemon.identified"])
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
        let marks = DaemonConnectMarks { received.append($0) }
        let provider = standIn.launcher.spawnObservingEndpointProvider(onSpawned: { marks.mark(.spawned) })
        _ = try await provider()
        _ = try await provider()
        #expect(received.names == ["daemon.spawned"])
    }

    @Test("An ensure that found a running owner marks no spawn")
    func runningOwnerMarksNoSpawn() async throws {
        let standIn = try StandIn(ensureStatus: "running")
        defer { standIn.remove() }
        let received = Received()
        let marks = DaemonConnectMarks { received.append($0) }
        _ = try await standIn.launcher.spawnObservingEndpointProvider(onSpawned: { marks.mark(.spawned) })()
        #expect(received.names.isEmpty)
    }

    @Test("A failed first connect marks only that it started")
    func failedPrestartMarksOnlyItsStart() async throws {
        let standIn = try StandIn(ensureStatus: nil)
        defer { standIn.remove() }
        let received = Received()
        let prestart = DaemonPrestart(launcher: standIn.launcher,
                                      configuration: DaemonConnection.Configuration(terminalEnvironment: nil),
                                      marks: DaemonConnectMarks { received.append($0) })
        #expect(received.names == ["daemon.connect_started"], "marked when main begins the attempt")
        guard case .failure = await prestart.outcome() else {
            Issue.record("the stand-in's ensure fails, so the attempt must fail")
            return
        }
        #expect(received.names == ["daemon.connect_started"])
    }

    /// A stand-in `cmux-tui`: `server status` finds no owner and `server ensure` answers `ensureStatus`
    /// (`started` or `running`), or fails when it is nil. Never a real daemon.
    struct StandIn {
        let root: URL
        let launcher: DaemonLauncher

        init(ensureStatus: String?) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cn-connect-marks-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            root = directory
            let session = "cn-connect-marks-\(UUID().uuidString.prefix(8).lowercased())"
            let socket = directory.appendingPathComponent("owner.sock").path
            let ensure = ensureStatus.map {
                "echo '{\"status\":\"\($0)\",\"session\":\"\(session)\",\"socket\":\"\(socket)\",\"pid\":4242,\"generation\":\"g-1\"}'; exit 0"
            } ?? "echo '{\"code\":\"server.spawn_failed\",\"message\":\"could not start the session owner\"}' >&2; exit 3"
            let script = """
            #!/bin/sh
            case " $* " in
            *" server status "*) exit 1 ;;
            *" server ensure "*) \(ensure) ;;
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
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The whole first connect against the same-tree daemon: a fresh session spawns its owner, so all four milestones
/// go out, once each and in launch order.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct DaemonConnectMarksLiveTests {
    @Test("A cold first connect marks connect_started, spawned, identified, snapshot_received once each")
    func coldPrestartMarksEveryMilestone() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-cm-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: ProcessInfo.processInfo.environment,
                                                                    overrides: [:])
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-connect-marks-live"),
            configuration: .init(binary: binary, session: "cnd-cm-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        let received = DaemonConnectMarksTests.Received()
        let prestart = DaemonPrestart(launcher: launcher, configuration: BranchDaemonHarness.configuration(),
                                      marks: DaemonConnectMarks { received.append($0) })
        let (connection, _) = try await prestart.outcome().get()
        // The store's first snapshot takes the prefetched one, which marks its arrival before it returns.
        _ = try await connection.snapshot()
        await BranchDaemonHarness.shutDown(connection)
        #expect(received.names == ["daemon.connect_started", "daemon.spawned", "daemon.identified",
                                   "daemon.snapshot_received"])
    }
}

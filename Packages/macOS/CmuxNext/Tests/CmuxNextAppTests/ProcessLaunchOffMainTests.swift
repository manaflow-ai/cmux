import CmuxNextCloud
@testable import CmuxNextCompat
@testable import CmuxNextRemote
import CmuxNextRemoteBrowser
import CmuxNextVSCodeServer
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): the Remote, Cloud, VS Code and
/// remote browser children start on a `ProcessLauncher` queue, never on the caller's thread (Chromium's
/// content/browser/child_process_launcher_helper.cc), and run at the launcher's child priority. Each start
/// here comes from the main actor through an injected ``SpawnProbe``: a start that spawned by itself (the old
/// `process.run()` on the caller's actor) records no spawn and fails the test.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessLaunchOffMainTests {
    /// The one spawn a start makes: off the main thread, the child at `childPriority`.
    static func offMainSpawn(_ childPriority: WorkPriority) -> [SpawnProbe.Spawn] {
        [SpawnProbe.Spawn(onMain: false, qualityOfService: childPriority.processQoS)]
    }

    /// The check ``offMain(_:sourceLocation:)`` relies on can fail: a spawn on the main actor records a
    /// `.processSpawn` site there.
    @MainActor @Test func aSpawnOnTheMainActorRecordsAProcessSpawnSite() async throws {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        try Self.spawnHere(URL(fileURLWithPath: "/usr/bin/true"), reportingTo: table)
        await table.flush()
        #expect(table.sites.contains { $0.context == .main && $0.kind == .processSpawn })
        #endif
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Spawns `executable` through the checked seam on the calling thread, reporting to `table`.
    @MainActor
    static func spawnHere(_ executable: URL, reportingTo table: BlockingViolationTable) throws {
        let process = Process()
        process.executableURL = executable
        try BlockingViolationTable.$scoped.withValue(table) { try process.blockingRun() }
    }
    #endif

    /// The real launcher (its default spawn is the checked `blockingRun()`) spawns off the main thread.
    @Test func aProcessLauncherStartedFromTheMainActorSpawnsOffIt() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let launcher = ProcessLauncher(label: "com.cmuxterm.next.test.launcher", priority: .userBlocking, childPriority: .bestEffort)
        try await Self.offMain { try await launcher.launched(process) }
        #expect(process.qualityOfService == WorkPriority.bestEffort.processQoS)
    }

    @Test func anSSHRunFromTheMainActorSpawnsOffItAndReturnsItsOutput() async throws {
        let probe = SpawnProbe(childPriority: .bestEffort)
        let result = try await Self.offMain {
            try await SSHProcessRunner.run(["/bin/sh", "-c", "/bin/cat; exit 3"], input: .data(Data("script".utf8)),
                                           environment: [:], deadline: .seconds(20), label: "test run", launcher: probe.launcher)
        }
        #expect(await probe.recorded() == Self.offMainSpawn(.bestEffort))
        #expect(result.status == 3)
        #expect(result.stdout == "script")
    }

    @Test func anSSHRunOfAMissingProgramThrowsItsLaunchError() async {
        await #expect(throws: (any Error).self) {
            _ = try await SSHProcessRunner.run(["/no/such/ssh"], environment: [:], deadline: .seconds(5), label: "missing")
        }
    }

    @Test func hostCLILinesArriveFromAChildSpawnedOffTheMainActor() async throws {
        let probe = SpawnProbe(childPriority: .bestEffort)
        let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/sh"), environment: { [:] }, launcher: probe.launcher)
        let lines = try await Self.offMain {
            var received: [String] = []
            for try await line in cli.lines(["-c", "echo one; echo two"]) { received.append(line) }
            return received
        }
        #expect(await probe.recorded() == Self.offMainSpawn(.bestEffort))
        #expect(lines == ["one", "two"])
    }

    @Test func aHostCLIRunThatFailsEndsWithItsStatus() async {
        let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/sh"), environment: { [:] })
        do {
            for try await _ in cli.lines(["-c", "exit 4"]) {}
            Issue.record("a failing run ended cleanly")
        } catch let stop as HostCLIStop {
            #expect(stop.status == 4)
        } catch {
            Issue.record("a failing run ended with \(error)")
        }
    }

    @Test func aHostCLIRunOfAMissingBinaryEndsWithoutAStatus() async {
        let cli = HostCLI(binary: URL(fileURLWithPath: "/no/such/cmux-tui"), environment: { [:] })
        do {
            for try await _ in cli.lines(["acp"]) {}
            Issue.record("a missing binary ended cleanly")
        } catch let stop as HostCLIStop {
            #expect(stop.status == nil)
        } catch {
            Issue.record("a missing binary ended with \(error)")
        }
    }

    /// The lock is never held across the spawn. For a cancel, exactly one side stops the child: the launch
    /// (cancelled during it) or the close (cancelled after it). A normal finish stops nothing, whenever it
    /// comes: the child has exited and its pid may belong to another process.
    @Test func theRunGateNamesExactlyOneStopperAndNoneForAFinish() {
        let cancelledFirst = RunGate()
        #expect(!cancelledFirst.close(cancelled: true))
        #expect(!cancelledFirst.isOpen)

        let cancelledDuring = RunGate()
        #expect(cancelledDuring.isOpen)
        #expect(!cancelledDuring.close(cancelled: true), "a cancel during the launch found a started child")
        #expect(cancelledDuring.launched(), "the launch missed the cancel that came during it")

        let cancelledAfter = RunGate()
        #expect(!cancelledAfter.launched())
        #expect(cancelledAfter.close(cancelled: true), "a cancel after the launch did not stop the child")

        let finishedBeforeLaunchReturned = RunGate()
        #expect(!finishedBeforeLaunchReturned.close(cancelled: false))
        #expect(!finishedBeforeLaunchReturned.launched(), "a run that finished by itself was stopped")

        let finishedAfter = RunGate()
        #expect(!finishedAfter.launched())
        #expect(!finishedAfter.close(cancelled: false), "a run that finished by itself was stopped")
    }

    @Test func aChildProcessSpawnsOffTheMainActorAtItsLaunchersPriority() async throws {
        let probe = SpawnProbe(childPriority: .bestEffort)
        let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "echo ready; exec /bin/sleep 30"], environment: [:], launcher: probe.launcher)
        try await Self.offMain { try await child.start() }
        defer { child.terminate() }
        #expect(await probe.recorded() == Self.offMainSpawn(.bestEffort))
        let line = try await child.firstLine(within: .seconds(20), label: "test child") { $0 }
        #expect(line == "ready")
        child.terminate()
        #expect(await child.waitForExit() != 0)
    }

    @Test func aChildProcessOfAMissingBinaryThrowsFromStart() async {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/no/such/cmux-tui"), arguments: [], environment: [:])
        await #expect(throws: (any Error).self) { try await child.start() }
        #expect(child.pid == nil)
        #expect(!child.isRunning)
    }

    @Test func aServeWebServerSpawnsOffTheMainActorAndReportsItsURL() async throws {
        let launch = VSCodeServeWebLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'Web UI available at http://127.0.0.1:9999/?tkn=t'; exec /bin/sleep 30"],
            environment: [:]
        )
        let probe = SpawnProbe(childPriority: .bestEffort)
        let launcher = VSCodeServeWebProcessLauncher(startupTimeout: .seconds(20), launcher: probe.launcher)
        let started = try await Self.offMain { try await launcher.start(launch) }
        defer { started.handle.terminate() }
        #expect(await probe.recorded() == Self.offMainSpawn(.bestEffort))
        #expect(started.url.absoluteString == "http://127.0.0.1:9999/?tkn=t")
    }

    @Test func aServeWebBinaryThatCannotStartThrowsLaunchFailed() async {
        let launch = VSCodeServeWebLaunch(executableURL: URL(fileURLWithPath: "/no/such/code-tunnel"), arguments: [], environment: [:])
        do {
            _ = try await VSCodeServeWebProcessLauncher(startupTimeout: .seconds(5)).start(launch)
            Issue.record("a missing server started")
        } catch let error as VSCodeServeWebError {
            if case .launchFailed = error {} else { Issue.record("a missing server failed with \(error)") }
        } catch {
            Issue.record("a missing server failed with \(error)")
        }
    }

    /// The host's spawn is userBlocking (the person waits for the tab), but the host itself runs at
    /// userVisible for its whole life, never at the spawn's priority.
    @Test func theRemoteBrowserHostRunsBelowItsSpawnsPriority() {
        #expect(LocalRemoteBrowserHost.defaultLauncher().childPriority == .userVisible)
    }

    /// A stand-in host: reads the secret, says where it listens, then lives until its lifeline closes.
    @Test func aLocalRemoteBrowserHostSpawnsOffTheMainActorAndEndsWithItsLifeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-rb-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("fake-host")
        let script = "#!/bin/sh\nread secret\necho '{\"listening\":\"127.0.0.1:4567\"}'\nexec /bin/cat >/dev/null\n"
        try Data(script.utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)

        let probe = SpawnProbe(priority: .userBlocking, childPriority: .userVisible)
        let started = try await Self.offMain {
            try await LocalRemoteBrowserHost.start(executable: host, pageURL: nil, workRoot: root, environment: [:],
                                                   timeout: .seconds(20), launcher: probe.launcher)
        }
        #expect(await probe.recorded() == Self.offMainSpawn(.userVisible))
        #expect(started.endpoint.port == 4567)
        #expect(started.processIdentifier > 0)
        started.stop()
        #expect(await started.exitStatus() == 0)
    }

    @Test func aLocalRemoteBrowserHostThatCannotStartThrowsLaunch() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-rb-launch-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await LocalRemoteBrowserHost.start(executable: URL(fileURLWithPath: "/no/such/host"), pageURL: nil,
                                                       workRoot: root, environment: [:], timeout: .seconds(5))
            Issue.record("a missing host started")
        } catch let failure as LocalRemoteBrowserHost.Failure {
            if case .launch = failure {} else { Issue.record("a missing host failed with \(failure)") }
        } catch {
            Issue.record("a missing host failed with \(error)")
        }
    }

    /// Runs `body` from the main actor with a recording table bound, and expects no blocking site on main
    /// (``aSpawnOnTheMainActorRecordsAProcessSpawnSite()`` shows a spawn there would record one).
    @MainActor
    static func offMain<T: Sendable>(_ body: @MainActor () async throws -> T,
                                     sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        let value = try await BlockingViolationTable.$scoped.withValue(table) { try await body() }
        await table.flush()
        let onMain = table.sites.filter { $0.context == .main }.map(\.location)
        #expect(onMain.isEmpty, "the start blocked the main thread: \(onMain)", sourceLocation: sourceLocation)
        return value
        #else
        return try await body()
        #endif
    }
}

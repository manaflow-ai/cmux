import CmuxNextCloud
@testable import CmuxNextCompat
@testable import CmuxNextRemote
import CmuxNextRemoteBrowser
import CmuxNextVSCodeServer
import CmuxNextWakeups
import Foundation
import Testing

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): the Remote, Cloud, VS Code and
/// remote browser children start on a `ProcessLauncher` queue, never on the caller's thread (Chromium's
/// content/browser/child_process_launcher_helper.cc), and run at their priority's `processQoS`. Each start here
/// comes from the main actor and records no blocking site there.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessLaunchOffMainTests {
    @Test func anSSHRunFromTheMainActorFeedsStdinAndReturnsItsOutput() async throws {
        let result = try await Self.offMain {
            try await SSHProcessRunner.run(["/bin/sh", "-c", "/bin/cat; exit 3"], input: .data(Data("script".utf8)),
                                           environment: [:], deadline: .seconds(20), label: "test run")
        }
        #expect(result.status == 3)
        #expect(result.stdout == "script")
    }

    @Test func anSSHRunOfAMissingProgramThrowsItsLaunchError() async {
        await #expect(throws: (any Error).self) {
            _ = try await SSHProcessRunner.run(["/no/such/ssh"], environment: [:], deadline: .seconds(5), label: "missing")
        }
    }

    @Test func hostCLILinesArriveFromAChildStartedOffMain() async throws {
        let cli = HostCLI(binary: URL(fileURLWithPath: "/bin/sh"), environment: { [:] })
        let lines = try await Self.offMain {
            var received: [String] = []
            for try await line in cli.lines(["-c", "echo one; echo two"]) { received.append(line) }
            return received
        }
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

    /// The lock is never held across the spawn, and exactly one side stops a child whose stream closed:
    /// the launch (closed during it) or the close (closed after it); a stream closed first launches nothing.
    @Test func theRunGateNamesExactlyOneStopper() {
        let first = RunGate()
        #expect(!first.close())
        #expect(!first.isOpen)

        let during = RunGate()
        #expect(during.isOpen)
        #expect(!during.close(), "a close during the launch found a started child")
        #expect(!during.started(), "the launch missed the close that came during it")

        let after = RunGate()
        #expect(after.started())
        #expect(after.close(), "a close after the launch did not stop the child")
    }

    @Test func aChildProcessStartsOffMainAtItsPriority() async throws {
        let child = ChildProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "echo ready; exec /bin/sleep 30"], environment: [:], priority: .bestEffort)
        try await Self.offMain { try await child.start() }
        defer { child.terminate() }
        #expect(child.qualityOfService == WorkPriority.bestEffort.processQoS)
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

    @Test func aServeWebServerStartsOffMainAndReportsItsURL() async throws {
        let launch = VSCodeServeWebLaunch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'Web UI available at http://127.0.0.1:9999/?tkn=t'; exec /bin/sleep 30"],
            environment: [:]
        )
        let launcher = VSCodeServeWebProcessLauncher(startupTimeout: .seconds(20), priority: .bestEffort)
        let started = try await Self.offMain { try await launcher.start(launch) }
        defer { started.handle.terminate() }
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

    /// A stand-in host: reads the secret, says where it listens, then lives until its lifeline closes.
    @Test func aLocalRemoteBrowserHostStartsOffMainAndEndsWithItsLifeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-rb-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("fake-host")
        let script = "#!/bin/sh\nread secret\necho '{\"listening\":\"127.0.0.1:4567\"}'\nexec /bin/cat >/dev/null\n"
        try Data(script.utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)

        let started = try await Self.offMain {
            try await LocalRemoteBrowserHost.start(executable: host, pageURL: nil, workRoot: root, environment: [:],
                                                   timeout: .seconds(20))
        }
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

    /// Runs `body` from the main actor with a recording table bound, and expects no blocking site on main.
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

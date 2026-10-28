import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app waits for acpmux's ready signal, not a fixed time (2026-10-20: acpmux took 19 to 28 s
/// to say ready over 3.9 GB of chats, and the app gave up after 20 s, then started it again).
/// A daemon that keeps writing its log is still starting and is waited for; a daemon that writes
/// nothing for the whole stall time is given up on; one that exits fails at once.
@Suite(.serialized)
struct AcpmuxLaunchReadyWaitTests {
    /// A stand-in `acpmux` running `body` (fd 3 is the ready pipe; stdout goes to daemon.log).
    static func environment(_ body: String) throws -> AcpmuxEnvironment {
        let root = URL(fileURLWithPath: "/tmp/alr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = root.appendingPathComponent("acpmux")
        try "#!/bin/sh\n\(body)\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        return AcpmuxEnvironment(executable: acpmux, home: home, socketPath: home.appendingPathComponent("s.sock").path,
                                 daemonArguments: [], childEnvironment: [:])
    }

    /// The launcher an `AcpmuxHost` keeps, one per test.
    static func launcher() -> ChildProcessLauncher {
        ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.acpmux-tests", priority: .userBlocking)
    }

    static let readyLine = #"{"ready":true,"pid":1,"webUrl":"http://127.0.0.1:4567/?token=t"}"#

    /// The launch blocks its caller's thread (the home's creation), so it runs where ``AcpmuxHost``
    /// runs it: on a serial queue of its own, never this test's main actor; the spawn goes to `launcher`.
    actor Launcher {
        private nonisolated let queue = DispatchSerialQueue(label: "test.acpmux-launch", qos: .userInitiated)
        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

        func launch(_ environment: AcpmuxEnvironment, deadline: Duration,
                    launcher: ChildProcessLauncher) async throws -> AcpmuxWebEndpoint {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: deadline, launcher: launcher)
        }
    }

    @Test func aDaemonThatKeepsStartingPastTheStallTimeIsWaitedFor() async throws {
        // Logs a line every 0.2 s for 2.4 s, then says ready: longer than the 1 s stall time,
        // but never 1 s without a log write.
        let environment = try Self.environment("""
        i=0; while [ $i -lt 12 ]; do echo "loading $i"; sleep 0.2; i=$((i+1)); done
        echo '\(Self.readyLine)' >&3
        """)
        let endpoint = try await Launcher().launch(environment, deadline: .seconds(1), launcher: Self.launcher())
        #expect(endpoint.token == "t")
    }

    @Test func aDaemonThatWritesNothingFailsAfterTheStallTime() async throws {
        let environment = try Self.environment("echo started; sleep 30")
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await Launcher().launch(environment, deadline: .seconds(1), launcher: Self.launcher())
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aDaemonThatExitsFailsAtOnce() async throws {
        let environment = try Self.environment("echo bye; exit 3")
        await #expect(throws: AcpmuxDaemonLauncher.Failure.self) {
            _ = try await Launcher().launch(environment, deadline: .seconds(20), launcher: Self.launcher())
        }
    }
}

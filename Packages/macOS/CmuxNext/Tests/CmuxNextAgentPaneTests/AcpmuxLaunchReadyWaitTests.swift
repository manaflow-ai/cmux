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

    static let readyLine = #"{"ready":true,"pid":1,"webUrl":"http://127.0.0.1:4567/?token=t"}"#

    @Test func aDaemonThatKeepsStartingPastTheStallTimeIsWaitedFor() async throws {
        // Logs a line every 0.2 s for 2.4 s, then says ready: longer than the 1 s stall time,
        // but never 1 s without a log write.
        let environment = try Self.environment("""
        i=0; while [ $i -lt 12 ]; do echo "loading $i"; sleep 0.2; i=$((i+1)); done
        echo '\(Self.readyLine)' >&3
        """)
        let endpoint = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(1))
        #expect(endpoint.token == "t")
    }

    @Test func aDaemonThatWritesNothingFailsAfterTheStallTime() async throws {
        let environment = try Self.environment("echo started; sleep 30")
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// acpmux refuses the shared home's daemon from a runner `_work` or temp folder and says why
    /// on the ready line (cmux#25761): the launcher throws that text, not "exited".
    @Test func aDaemonThatRefusesSaysWhy() async throws {
        let why = "acpmux: this daemon's executable /tmp/a/acpmux is in a temporary folder"
        // A heredoc, not `echo '...'`: the reason has an apostrophe, which would end a quoted
        // echo and leave the ready pipe empty (the launcher then says "exited").
        let environment = try Self.environment("""
        cat >&3 <<'LINE'
        {"ready":false,"refused":"\(why)"}
        LINE
        """)
        await #expect(throws: AcpmuxDaemonLauncher.Failure.refused(why)) {
            _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(20))
        }
        #expect(AcpmuxFailureCause.refused(why).userText == why)
        #expect(AcpmuxReadyLine.refusal(Self.readyLine) == nil)
        #expect(AcpmuxReadyLine.refusal(#"{"ready":false,"lockHeld":true}"#) == nil)
    }

    /// A launch that lost the lock race relays the winner's readiness with `lockHeld` (acpmux#27336):
    /// the launcher says it did not start that daemon, and the enroll after it never hands the
    /// winner off, so it is never shut down under the client that started it.
    @Test func aRelayedLockHeldEndpointIsNeverHandedOff() async throws {
        let relayed = try Self.environment("""
        echo '{"ready":true,"lockHeld":true,"pid":1,"webUrl":"http://127.0.0.1:4567/?token=w"}' >&3
        """)
        let winner = try await AcpmuxDaemonLauncher.launchReporting(relayed, deadline: .seconds(20))
        #expect(winner.endpoint.token == "w")
        #expect(!winner.startedHere)
        #expect(!AcpmuxHost.mayHandOff(after: winner))

        let own = try Self.environment("echo '\(Self.readyLine)' >&3")
        let started = try await AcpmuxDaemonLauncher.launchReporting(own, deadline: .seconds(20))
        #expect(started.startedHere)
        #expect(AcpmuxHost.mayHandOff(after: started))
        #expect(AcpmuxReadyLine.parse(#"{"ready":true,"lockHeld":true}"#)?.lockHeld == true)
    }

    @Test func aDaemonThatExitsFailsAtOnce() async throws {
        let environment = try Self.environment("echo bye; exit 3")
        await #expect(throws: AcpmuxDaemonLauncher.Failure.self) {
            _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(20))
        }
    }
}

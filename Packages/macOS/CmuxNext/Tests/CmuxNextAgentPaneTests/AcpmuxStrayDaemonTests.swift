import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// One acpmux per machine (hq plans/cmux-next/acpmux-one-daemon.md, step 2): a daemon on the
/// app's acpmux home that no cmux install runs (a `~/.local/bin/acpmux` started by launchd or by
/// the CLI's autostart) is taken over, not refused. The app hands it off the way it hands off
/// another build: its agents detach and the bundled daemon adopts them. Before, the server peer
/// check refused it (its executable is not this app's) and every chat said acpmux did not start.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
struct AcpmuxStrayDaemonTests {
    @Test func chatsReachTheBundledAcpmuxWhenAStrayDaemonHoldsTheHome() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/asd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("app/bin", isDirectory: true)
        let localBin = root.appendingPathComponent("local/bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("s.sock").path
        for directory in [bin, localBin, home] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        try FileManager.default.copyItem(at: binary, to: localBin.appendingPathComponent("acpmux"))
        func environment(_ directory: URL) throws -> AcpmuxEnvironment {
            try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: directory,
                                                   environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket],
                                                   executableOverride: nil))
        }

        var step = "the stray daemon's start"
        let pids: Result<(Int32?, Int32?), any Error>
        do {
            // The CLI's autostart (or launchd) runs `~/.local/bin/acpmux` on the app's home.
            try await AcpmuxHost(environment: try environment(localBin)).prewarm()
            let before = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            // The app's launch: its chats connect, to an acpmux run from its own bundle.
            step = "the app's launch"
            try await AcpmuxHost(environment: try environment(bin)).prewarm()
            pids = .success((before, try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid))
        } catch {
            pids = .failure(error)
        }
        let log = (try? String(contentsOf: home.appendingPathComponent("daemon.log"), encoding: .utf8))
            .map { $0.split(separator: "\n").suffix(30).joined(separator: "\n") } ?? "no daemon.log"
        let running: String? = if case .success(let (_, after?)) = pids { AcpmuxVersionHandoff.executablePath(pid: after) } else { nil }
        // Whatever failed, every daemon this test started ends with it.
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: home, deadline: .seconds(10))
        guard case .success(let (before, after)) = pids, let pid = after else {
            Issue.record("\(step) failed: \(pids)\n--- daemon.log\n\(log)")
            return
        }
        #expect(await AgentPaneProcessExit(pid: pid).event(within: .seconds(10)), "the daemon outlived its shutdown")
        #expect(pid != before, "the stray daemon still answers")
        let path = try #require(running)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == bin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path)
    }

    // Only a daemon no cmux install runs is stray: another install's bundle (NIGHTLY shares
    // `~/.acpmux` with older builds) keeps the peer check's rules, and the app's own is not.
    @Test func onlyADaemonOutsideEveryAppBundleIsStray() {
        let own = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux")
        #expect(AcpmuxStrayDaemon.isStray(runningPath: "/Users/me/.local/bin/acpmux", executable: own))
        #expect(AcpmuxStrayDaemon.isStray(runningPath: "/opt/homebrew/bin/acpmux", executable: own))
        #expect(!AcpmuxStrayDaemon.isStray(runningPath: own.path, executable: own))
        #expect(!AcpmuxStrayDaemon.isStray(runningPath: "/Applications/cmux NIGHTLY 2.app/Contents/Resources/bin/acpmux", executable: own))
        #expect(!AcpmuxStrayDaemon.isStray(runningPath: nil, executable: own))
    }

    // A launchd agent that runs the stray daemon would start it again after the hand-off: it is
    // found by its program and booted out first.
    @Test func theLaunchAgentThatRunsTheStrayDaemonIsFound() {
        let agents: [[String: Any]] = [
            ["Label": "com.acpmux.daemon", "ProgramArguments": ["/Users/me/.local/bin/acpmux", "daemon", "run"]],
            ["Label": "com.example.other", "ProgramArguments": ["/usr/local/bin/other"]],
            ["Label": "com.acpmux.program", "Program": "/Users/me/.local/bin/acpmux"],
            ["ProgramArguments": ["/Users/me/.local/bin/acpmux"]],
        ]
        #expect(AcpmuxStrayDaemon.launchAgentLabels(programPath: "/Users/me/.local/bin/acpmux", agents: agents)
                == ["com.acpmux.daemon", "com.acpmux.program"])
        let printed = "gui/501/com.acpmux.daemon = {\n\tactive count = 1\n\tpath = /Users/me/Library/LaunchAgents/com.acpmux.daemon.plist\n\tstate = running\n\tpid = 4242\n}\n"
        #expect(AcpmuxStrayDaemon.pid(fromLaunchctlPrint: printed) == 4242)
        #expect(AcpmuxStrayDaemon.pid(fromLaunchctlPrint: "gui/501/x = {\n\tstate = not running\n}\n") == nil)
    }
}

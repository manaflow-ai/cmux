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
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment(localBin)).prewarm()
            let before = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            // The app's launch: its chats connect, to an acpmux run from its own bundle.
            step = "the app's launch"
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment(bin)).prewarm()
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
        let stray = try #require(before)
        #expect(pid != stray, "the stray daemon still answers")
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

    // A launchd job that runs the stray daemon would start it again after the hand-off: it is
    // found by its pid in the user domain's services and booted out first.
    @Test func theLaunchdJobThatRunsTheStrayDaemonIsFoundByItsPid() {
        let domain = """
        gui/501 = {
        \ttype = gui
        \tservices = {
        \t\t       0      0 \tcom.apple.idle
        \t\t    4242      - \tcom.acpmux.daemon
        \t\t    4300      0 \tcom.example.wrapper
        \t\t    4400      0 \tapplication.com.github.wez.wezterm.1.2
        \t\t       -     78 \tcom.example.stopped
        \t}
        \tendpoints = {
        \t\t    4242      0 \tnot.a.service
        \t}
        }
        """
        #expect(AcpmuxStrayDaemon.labels(runningAnyOf: [4242], fromDomainPrint: domain) == ["com.acpmux.daemon"])
        #expect(AcpmuxStrayDaemon.labels(runningAnyOf: [4242, 4300], fromDomainPrint: domain) == ["com.acpmux.daemon", "com.example.wrapper"])
        #expect(AcpmuxStrayDaemon.labels(runningAnyOf: [9], fromDomainPrint: domain).isEmpty)
        // An app that runs that pid (a terminal that started the daemon itself) is never booted out.
        #expect(AcpmuxStrayDaemon.labels(runningAnyOf: [4400], fromDomainPrint: domain).isEmpty)
        let printed = "gui/501/com.acpmux.daemon = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n}\n"
        #expect(AcpmuxStrayDaemon.pid(fromLaunchctlPrint: printed) == 4242)
        #expect(AcpmuxStrayDaemon.pid(fromLaunchctlPrint: "gui/501/x = {\n\tstate = not running\n}\n") == nil)
    }
}

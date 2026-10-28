import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// An update that replaces the app bundle while two of its acpmux homes run a daemon from it:
/// the app's own home and a Chief home's own acpmux, where subagents from before the move still
/// run (cosmic-gray, 2026-10-25). The new launch handed the first daemon off to the bundled
/// build, then refused the second: the handoff ran once per bundled build for the whole app, not
/// once per daemon, so the second daemon kept running from the deleted file. Its chats said
/// "Another acpmux service is using this socket" and every retry, Retry included, said it again
/// until the app relaunched.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
struct AcpmuxTwoHomesUpdateTests {
    @Test func everyHomeReachesTheBundledAcpmuxAfterTheBundleIsReplaced() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/ath-\(UUID().uuidString.prefix(8))", isDirectory: true)
        // Inside an app bundle, as an installed cmux is: its daemon is never a stray one.
        let app = root.appendingPathComponent("T.app", isDirectory: true)
        let bin = app.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let homes = ["a", "b"].map { root.appendingPathComponent($0, isDirectory: true) }
        let sockets = homes.map { $0.appendingPathComponent("s.sock").path }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for home in homes { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        func environment(_ index: Int) throws -> AcpmuxEnvironment {
            try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin,
                                                   environment: ["ACPMUX_HOME": homes[index].path, "ACPMUX_SOCKET": sockets[index]],
                                                   executableOverride: nil))
        }
        func pid(_ index: Int) async throws -> Int32? {
            try await AcpmuxStatusClient.status(socketPath: sockets[index], deadline: .seconds(15)).pid
        }

        // Every daemon this test starts, with its start time read while it runs, so each one ends
        // with the test whatever failed, and a pid reused since is never signalled.
        var started: [Int32: UInt64] = [:]
        func record(_ pid: Int32?) {
            if let pid, let start = Self.startTime(pid) { started[pid] = start }
        }
        var step = "build N's launch"
        var outcome: Result<[Int32?], any Error> = .success([])
        do {
            // Build N starts acpmux from its bundle on both homes.
            var before: [Int32?] = []
            for index in homes.indices {
                try await AcpmuxHost(environment: try environment(index)).prewarm()
                let now = try await pid(index)
                before.append(now)
                record(now)
            }
            // The update: the bundle goes aside and away, the new one takes its place.
            step = "the bundle swap"
            let aside = root.appendingPathComponent("T.old.app", isDirectory: true)
            try FileManager.default.moveItem(at: app, to: aside)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
            try FileManager.default.removeItem(at: aside)
            // Build N+1: a chat on each home connects, the app's home first.
            var after: [Int32?] = []
            for index in homes.indices {
                step = "build N+1's launch on home \(homes[index].lastPathComponent)"
                try await AcpmuxHost(environment: try environment(index)).prewarm()
                let now = try await pid(index)
                after.append(now)
                record(now)
                #expect(now != before[index], "home \(homes[index].lastPathComponent)'s old daemon still answers")
            }
            outcome = .success(after)
        } catch {
            outcome = .failure(error)
        }
        // What each new daemon runs from, read while it still runs.
        var running: [String?] = []
        if case .success(let after) = outcome {
            running = after.map { $0.flatMap(AcpmuxVersionHandoff.executablePath(pid:)) }
        }
        let logs = homes.map { home in
            (try? String(contentsOf: home.appendingPathComponent("daemon.log"), encoding: .utf8))
                .map { $0.split(separator: "\n").suffix(20).joined(separator: "\n") } ?? "no daemon.log"
        }
        for (index, socket) in sockets.enumerated() {
            _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: homes[index], deadline: .seconds(10))
        }
        for (pid, start) in started {
            // A daemon the app refused may outlive the shutdown above: it is signalled only while
            // its pid still names the process this test started (same start time).
            if await !AgentPaneProcessExit(pid: pid).event(within: .seconds(10)), Self.startTime(pid) == start {
                kill(pid, SIGKILL)
                _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(10))
            }
        }
        guard case .success = outcome else {
            Issue.record("\(step) failed: \(outcome)\n--- a/daemon.log\n\(logs[0])\n--- b/daemon.log\n\(logs[1])")
            return
        }
        let bundled = bin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path
        for (index, path) in running.enumerated() {
            #expect(path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == bundled,
                    "home \(homes[index].lastPathComponent) does not run the bundled acpmux")
        }
    }

    /// When process `pid` started (`proc_bsdinfo`), in microseconds; nil when it does not run.
    static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}

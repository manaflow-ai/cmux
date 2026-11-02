import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The tree's acpmux (`pin-cmux-tui.sh acpmux-path`, after a tree fetch).
nonisolated enum SameTreeAcpmuxBinary {
    static let url: URL? = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/cmux-next/pin-cmux-tui.sh").path, "acpmux-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()
}

/// An update that replaces the app bundle in place (update-dev-daily.sh, cx-ame2k): the old
/// bundle is renamed aside and deleted, and its acpmux keeps running from the deleted file,
/// with the chats' agents under it. The next launch's chats must reach acpmux by themselves.
/// Before, the server peer check refused that daemon (its executable is not this app's) and
/// every chat said "acpmux did not start", even with the same build.
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeAcpmuxBinary.url != nil, "needs the same-tree acpmux"))
struct AcpmuxBundleReplacedTests {
    @Test func chatsReachAcpmuxAfterTheBundleIsReplaced() async throws {
        let binary = try #require(SameTreeAcpmuxBinary.url)
        let root = URL(fileURLWithPath: "/tmp/abr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("app/bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("s.sock").path
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        func environment() throws -> AcpmuxEnvironment {
            try #require(AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: bin,
                                                   environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket],
                                                   executableOverride: nil))
        }

        // Each step is named, so a failure says whether the update or the setup broke.
        var step = "build N's launch"
        let pids: Result<(Int32?, Int32?), any Error>
        do {
            // Build N's launch starts acpmux from its bundle.
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment()).prewarm()
            let before = try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid
            // The update: the bundle goes aside and away, the new one takes its place.
            step = "the bundle swap"
            let app = bin.deletingLastPathComponent()
            let aside = root.appendingPathComponent("app.old", isDirectory: true)
            try FileManager.default.moveItem(at: app, to: aside)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
            try FileManager.default.removeItem(at: aside)
            // Build N+1's launch: its chats connect, to an acpmux run from its own bundle.
            step = "build N+1's launch"
            try await AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: try environment()).prewarm()
            pids = .success((before, try await AcpmuxStatusClient.status(socketPath: socket, deadline: .seconds(15)).pid))
        } catch {
            pids = .failure(error)
        }
        let log = (try? String(contentsOf: home.appendingPathComponent("daemon.log"), encoding: .utf8))
            .map { $0.split(separator: "\n").suffix(30).joined(separator: "\n") } ?? "no daemon.log"
        // Read what the new daemon runs from while it still runs: after its shutdown the
        // pid is gone and proc_pidpath returns 0.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var pathLength: Int32 = 0
        if case .success(let (_, after?)) = pids { pathLength = proc_pidpath(after, &path, UInt32(path.count)) }
        // Whatever failed, every daemon this test started ends with it.
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket, home: home, deadline: .seconds(10))
        guard case .success(let (before, after)) = pids, let pid = after else {
            Issue.record("\(step) failed: \(pids)\n--- daemon.log\n\(log)")
            return
        }
        // The shut-down daemon is gone before the test ends.
        let exitDeadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0, ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(pid, 0) != 0, "the daemon outlived its shutdown")
        #expect(pid != before, "the old daemon still answers")
        #expect(pathLength > 0)
        let running = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(URL(fileURLWithPath: running).resolvingSymlinksInPath().path
                == bin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path)
    }
}

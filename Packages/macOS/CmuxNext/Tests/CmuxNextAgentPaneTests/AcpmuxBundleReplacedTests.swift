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
            try #require(AcpmuxEnvironment.resolve(tag: nil, bundledBinDirectory: bin,
                                                   environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket]))
        }

        // Build N's launch starts acpmux from its bundle.
        try await AcpmuxHost(environment: try environment()).prewarm()
        let before = try await AcpmuxStatusClient.status(socketPath: socket).pid
        // The update: the bundle goes aside and away, the new one takes its place.
        let aside = root.appendingPathComponent("app.old", isDirectory: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("app"), to: aside)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: bin.appendingPathComponent("acpmux"))
        try FileManager.default.removeItem(at: aside)

        // Build N+1's launch: its chats connect, to an acpmux run from its own bundle.
        let result: Result<Void, any Error>
        do { result = .success(try await AcpmuxHost(environment: try environment()).prewarm()) } catch { result = .failure(error) }
        let after = try? await AcpmuxStatusClient.status(socketPath: socket).pid
        _ = try? await AcpmuxStatusClient.shutdown(socketPath: socket)
        try result.get()
        let pid = try #require(after)
        #expect(pid != before, "the old daemon still answers")
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        #expect(proc_pidpath(pid, &path, UInt32(path.count)) > 0)
        #expect(URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
                == bin.appendingPathComponent("acpmux").resolvingSymlinksInPath().path)
    }
}

import Foundation
import Testing
@testable import CmuxNextDaemon

/// `bundledBuild()` reads the packaged `bin/cmux-tui.version.json` and runs no binary when it is
/// there: the first exec of a new app copy's cmux-tui cost about 800 ms before daemon_connected
/// (launch-tti job 140262416321, handshake to daemon_connected p50 768 ms cold, 322 ms warm).
/// Without the file, or when it does not parse, the binary runs as before.
struct DaemonBundledBuildStampTests {
    /// A `bin/` with a fake `cmux-tui` that records each run in `ran` and answers `--version --json`
    /// with build `exec1234`.
    private struct Bin {
        let dir: URL
        var binary: URL { dir.appendingPathComponent("cmux-tui") }
        var ran: URL { dir.appendingPathComponent("ran") }
        var stamp: URL { DaemonLauncher.buildStampFile(beside: binary) }

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cnd-build-stamp-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                echo "$@" >> '\(dir.appendingPathComponent("ran").path)'
                echo '{"app":"cmux-tui","build_commit":"exec1234","build_identity":"exec1234"}'
                """
            try Data(script.utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }

        func launcher() -> DaemonLauncher {
            DaemonLauncher(configuration: .init(binary: binary, session: "cnd-build-stamp"), environment: { [:] })
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func aPackagedStampIsReadWithoutRunningTheBinary() async throws {
        let bin = try Bin()
        defer { bin.remove() }
        try Data(#"{"app":"cmux-tui","build_commit":"file5678","build_identity":"file5678"}"#.utf8).write(to: bin.stamp)
        let stamp = try await bin.launcher().bundledBuild()
        #expect(stamp == DaemonBuildStamp(commit: "file5678", id: "file5678"))
        #expect(!FileManager.default.fileExists(atPath: bin.ran.path))
    }

    @Test func withoutAStampTheBinaryRuns() async throws {
        let bin = try Bin()
        defer { bin.remove() }
        let stamp = try await bin.launcher().bundledBuild()
        #expect(stamp == DaemonBuildStamp(commit: "exec1234", id: "exec1234"))
        #expect(try String(contentsOf: bin.ran, encoding: .utf8).contains("--version --json"))
    }

    @Test(arguments: ["not json", "{}", #"{"build_commit":null,"build_identity":null}"#, ""])
    func aStampThatGivesNoBuildFallsBackToTheBinary(_ contents: String) async throws {
        let bin = try Bin()
        defer { bin.remove() }
        try Data(contents.utf8).write(to: bin.stamp)
        let stamp = try await bin.launcher().bundledBuild()
        #expect(stamp == DaemonBuildStamp(commit: "exec1234", id: "exec1234"))
        #expect(FileManager.default.fileExists(atPath: bin.ran.path))
    }

    @Test func theStampIsBesideTheBundledBinary() {
        let binary = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux-tui")
        #expect(DaemonLauncher.buildStampFile(beside: binary).path
            == "/Applications/cmux.app/Contents/Resources/bin/cmux-tui.version.json")
    }
}

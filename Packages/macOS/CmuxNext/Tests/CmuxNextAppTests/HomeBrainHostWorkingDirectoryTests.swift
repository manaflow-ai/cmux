import Foundation
import Testing
@testable import CmuxNextApp

/// LAUNCH-NO-TCC-PROMPTS for the Chief: the brain host, and everything it
/// starts without its own folder (its acpmux daemon), runs in the Chief
/// home, never in the app's working folder (`/` for a Finder launch) or the
/// home folder. An agent there reads the protected folders at once, and
/// macOS asks for Downloads, Documents and Desktop in the app's name
/// (live incident 2026-10-09, nxdog81).
@Suite(.timeLimit(.minutes(1))) nonisolated struct HomeBrainHostWorkingDirectoryTests {
    @Test func theHostRunsInTheChiefHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-cwd-\(UUID().uuidString)", isDirectory: true)
        let muxHome = root.appendingPathComponent("chief", isDirectory: true)
        try FileManager.default.createDirectory(at: muxHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("cwd.txt")
        // A stand-in host: records its working folder, then exits.
        let script = root.appendingPathComponent("fake-host.sh")
        try "#!/bin/sh\n/bin/pwd -P > '\(report.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let host = HomeBrainHost(executable: script, muxHome: muxHome, daemonSocket: root.appendingPathComponent("d.sock").path,
                                 controlSocket: root.appendingPathComponent("c.sock").path, acpmux: nil)
        await host.launch(agentToken: "token")

        // The host is detached: poll its report (bounded).
        var cwd = ""
        for _ in 0..<200 where cwd.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
            cwd = ((try? String(contentsOf: report, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(cwd == Self.realPath(muxHome.path))
        #expect(cwd != "/")
        #expect(cwd != Self.realPath(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// `realpath(3)`, as `pwd -P` reports it (`/var` is `/private/var`).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

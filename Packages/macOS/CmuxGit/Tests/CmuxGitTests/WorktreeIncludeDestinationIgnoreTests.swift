import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorktreeIncludeDestinationIgnoreTests {
    @Test func dirtySourceIgnoreRuleCannotExposeSecretInDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-worktreeinclude-destination-ignore-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: source)
        try "# committed ignore rules\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "tracked\n".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", ".gitignore", ".worktreeinclude", "README.md"], in: source)
        try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit", "--quiet", "-m", "initial",
        ], in: source)
        try runGit(["worktree", "add", "--quiet", "--detach", destination.path, "HEAD"], in: source)

        try ".env\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: source.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("destination") })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".env").path))
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "WorktreeIncludeDestinationIgnoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: details]
            )
        }
    }
}

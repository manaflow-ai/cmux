import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("System artifact Git command runner")
struct SystemArtifactGitCommandRunnerTests {
    @Test("Ambient Git repository overrides are removed")
    func removesAmbientGitOverrides() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try runGit(["init", "--quiet", root.path])
        let tracked = try ArtifactTestSupport.write("tracked", named: "tracked.md", under: root)
        try runGit(["-C", root.path, "add", "tracked.md"])
        let alternateIndex = root.appendingPathComponent("alternate-index")
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_INDEX_FILE"] = alternateIndex.path
        environment["GIT_WORK_TREE"] = root.appendingPathComponent("wrong-worktree").path
        let runner = SystemArtifactGitCommandRunner(environment: environment)

        let status = try await runner.terminationStatus(arguments: [
            "-C", root.path,
            "ls-files", "--error-unmatch", "--", tracked.lastPathComponent,
        ])

        #expect(status == 0)
    }

    @Test("Cancellation terminates a running command promptly")
    func cancelsRunningCommand() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let started = root.appendingPathComponent("started")
        let runner = SystemArtifactGitCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5
        )
        let task = Task {
            try await runner.terminationStatus(arguments: [
                "-c", "printf ready > \(started.path); while :; do :; done",
            ])
        }
        #expect(await waitUntilFileExists(started))

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("The command deadline terminates a stalled child")
    func timesOutStalledCommand() async throws {
        let runner = SystemArtifactGitCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.05
        )

        await #expect(throws: ArtifactGitCommandError.timedOut) {
            _ = try await runner.terminationStatus(arguments: ["-c", "while :; do :; done"])
        }
    }

    private func waitUntilFileExists(_ url: URL) async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

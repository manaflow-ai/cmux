import CmuxFoundation
@testable import CmuxWorktrees
import Foundation

struct GitTestRepository: Sendable {
    let root: URL
    let repository: URL
    let runner: CommandRunner
    let host: LocalWorktreeExecutionHost

    static func make(name: String = "repo") async throws -> GitTestRepository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktrees-tests-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_ALLOW_PROTOCOL"] = "file"
        let runner = CommandRunner(environment: environment, bundledBinPath: nil)
        let host = LocalWorktreeExecutionHost(
            homeDirectory: root.appendingPathComponent("home", isDirectory: true).path,
            commandRunner: runner,
            additionalEnvironment: ["GIT_ALLOW_PROTOCOL": "file"]
        )
        let fixture = GitTestRepository(root: root, repository: repository, runner: runner, host: host)
        _ = try await fixture.git(["init", "-b", "main"])
        _ = try await fixture.git(["config", "user.name", "cmux tests"])
        _ = try await fixture.git(["config", "user.email", "cmux-tests@example.com"])
        try fixture.write("initial\n", to: "README.md")
        _ = try await fixture.git(["add", "README.md"])
        _ = try await fixture.git(["commit", "-m", "initial"])
        _ = try await fixture.git(["branch", "-M", "main"])
        return fixture
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func write(_ contents: String, to relativePath: String, in directory: URL? = nil) throws {
        let base = directory ?? repository
        let url = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func git(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        let result = await gitRaw(arguments, in: directory, timeout: timeout)
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else {
            throw WorktreeServiceError.commandFailed(
                command: (["git"] + arguments).joined(separator: " "),
                exitStatus: result.exitStatus,
                message: [result.stderr, result.stdout].compactMap { $0 }.joined(separator: "\n")
            )
        }
        return result
    }

    func gitRaw(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 30
    ) async -> CommandResult {
        await runner.run(
            directory: (directory ?? repository).path,
            executable: "git",
            arguments: arguments,
            timeout: timeout
        )
    }

    func commit(_ message: String, in directory: URL? = nil) async throws {
        _ = try await git(["add", "-A"], in: directory)
        _ = try await git(["commit", "-m", message], in: directory)
    }
}

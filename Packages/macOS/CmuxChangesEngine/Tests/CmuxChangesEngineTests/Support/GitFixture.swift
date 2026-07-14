import CmuxFoundation
import Foundation

struct GitFixture {
    let root: URL
    private let runner = CommandRunner()

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxChangesEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await git(["init", "-q"])
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let result = await runner.run(
            directory: root.path,
            executable: "/usr/bin/git",
            arguments: ["-c", "core.quotepath=false"] + arguments,
            timeout: 30
        )
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else {
            throw GitFixtureError.commandFailed(
                result.executionError ?? result.stderr ?? "git status \(result.exitStatus.map(String.init) ?? "unknown")"
            )
        }
        return result.stdout ?? ""
    }

    func commit(_ message: String = "fixture") async throws {
        _ = try await git([
            "-c", "user.email=fixture@example.com",
            "-c", "user.name=Cmux Changes Tests",
            "commit", "-qm", message,
        ])
    }

    func commitAll(_ message: String = "fixture") async throws {
        _ = try await git(["add", "-A"])
        try await commit(message)
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, Data(text.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

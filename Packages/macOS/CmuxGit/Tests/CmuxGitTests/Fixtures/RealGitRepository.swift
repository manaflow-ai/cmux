import Foundation

/// A disposable repository driven by the system Git executable for integration tests.
final class RealGitRepository {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func write(_ path: String, contents: String) throws {
        try write(path, data: Data(contents.utf8))
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_AUTHOR_NAME"] = "Cmux Tests"
        environment["GIT_AUTHOR_EMAIL"] = "cmux-tests@example.com"
        environment["GIT_COMMITTER_NAME"] = "Cmux Tests"
        environment["GIT_COMMITTER_EMAIL"] = "cmux-tests@example.com"
        process.environment = environment
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "git failed"
            throw NSError(
                domain: "RealGitRepository",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

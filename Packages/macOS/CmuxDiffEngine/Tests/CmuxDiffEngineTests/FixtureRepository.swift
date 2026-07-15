import Foundation

struct FixtureRepository {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxDiffEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "cmux diff tests"])
        try git(["config", "user.email", "diff-tests@example.invalid"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func write(_ data: Data, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func commitAll(_ message: String = "fixture") throws -> String {
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", message])
        return try gitOutput(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func git(_ arguments: [String]) throws {
        _ = try gitOutput(arguments)
    }

    func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureRepositoryError.gitFailed(
                arguments: arguments,
                diagnostic: String(decoding: diagnostic, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}

import Foundation

final class WorkspaceChangesGitRepositoryFixture {
    let root: URL
    let home: URL

    init(initializeRepository: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-changes-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if initializeRepository {
            try git(["init", "-b", "main"])
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeBaseline() throws {
        try write("tracked.txt", "base\n")
        try git(["add", "tracked.txt"])
        try commit("baseline")
    }

    func write(_ path: String, _ contents: String) throws {
        try write(path, Data(contents.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    func commit(_ message: String) throws {
        try git([
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "-m", message,
        ])
    }

    @discardableResult
    func git(_ arguments: [String], acceptedExitCodes: Set<Int32> = [0]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["HOME"] = home.path
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            throw FixtureError.gitFailed(
                arguments: arguments,
                exitCode: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
            )
        }
        return outputData
    }

    enum FixtureError: Error {
        case gitFailed(arguments: [String], exitCode: Int32, message: String)
    }
}

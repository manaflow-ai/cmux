import Foundation
@testable import CmuxGit

final class WorkspaceChangesGitRepositoryFixture {
    let root: URL
    let home: URL
    private(set) var gitExecutableURL: URL
    private let gitExecutableURLs: [URL]

    init(initializeRepository: Bool = true, gitExecutableURL: URL? = nil) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-changes-\(UUID().uuidString)", isDirectory: true)
        self.root = rootURL
        self.home = rootURL.appendingPathComponent("home", isDirectory: true)
        self.gitExecutableURLs = gitExecutableURL.map { [$0] }
            ?? SystemGitExecutableResolver().referenceExecutableURLs()
        self.gitExecutableURL = self.gitExecutableURLs[0]
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
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
        var lastFailure: FixtureError?
        for executableURL in gitExecutableURLs {
            let process = Process()
            process.executableURL = executableURL
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
            do {
                try process.run()
            } catch {
                lastFailure = .gitFailed(
                    arguments: arguments,
                    exitCode: -1,
                    message: String(describing: error)
                )
                continue
            }
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if acceptedExitCodes.contains(process.terminationStatus) {
                gitExecutableURL = executableURL
                return outputData
            }
            lastFailure = .gitFailed(
                arguments: arguments,
                exitCode: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
            )
        }
        throw lastFailure ?? .gitFailed(arguments: arguments, exitCode: -1, message: "Git unavailable")
    }

    enum FixtureError: Error {
        case gitFailed(arguments: [String], exitCode: Int32, message: String)
    }
}

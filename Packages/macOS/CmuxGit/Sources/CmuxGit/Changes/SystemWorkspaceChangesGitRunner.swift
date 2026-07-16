import Foundation

/// Runs `/usr/bin/git` with optional locking disabled.
struct SystemWorkspaceChangesGitRunner: WorkspaceChangesGitRunning {
    private let executableURL: URL
    private let environment: [String: String]

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        var nonLockingEnvironment = environment
        nonLockingEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        self.environment = nonLockingEnvironment
    }

    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return WorkspaceChangesGitResult(output: output, exitCode: process.terminationStatus)
    }
}

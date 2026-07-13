import Foundation

/// Git operations the store needs for git-sourced templates.
///
/// Cloning happens at install/update time only; installation never executes
/// anything from the template itself — `git` is the single external process
/// the store may spawn, and only against the URL the user provided.
public protocol OrchestrationGitClient: Sendable {
    /// Clones `url` (optionally a specific `reference`) into `path`, which
    /// must not exist yet. Returns the checked-out commit hash if known.
    func clone(url: String, reference: String?, toPath path: String) throws -> String?
}

public struct OrchestrationGitError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Runs the system `git` binary.
public struct DefaultOrchestrationGitClient: OrchestrationGitClient {
    public init() {}

    public func clone(url: String, reference: String?, toPath path: String) throws -> String? {
        var arguments = ["clone", "--depth", "1"]
        if let reference {
            arguments += ["--branch", reference]
        }
        arguments += ["--", url, path]
        try runGit(arguments, currentDirectory: nil)
        let commit = try? runGit(["rev-parse", "HEAD"], currentDirectory: path)
        return commit?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(_ arguments: [String], currentDirectory: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw OrchestrationGitError(message: "failed to launch git: \(error.localizedDescription)")
        }
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OrchestrationGitError(
                message: "git \(arguments.first ?? "") failed (exit \(process.terminationStatus))"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}

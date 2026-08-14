import CmuxFoundation
import Darwin
import Foundation

extension GitMetadataService {
    /// Branch name git writes into the vestigial `HEAD` stub for reftable repos.
    static let reftableHeadBranchSentinel = ".invalid"

    private enum GitPlumbingRunnerOverride {
        @TaskLocal static var current: (any GitMetadataGitRunning)?
    }

    /// Runs `body` with a git-plumbing runner override isolated to this task.
    static func withGitPlumbingRunnerForTesting<T>(
        _ runner: any GitMetadataGitRunning,
        perform body: () async throws -> T
    ) async rethrows -> T {
        try await GitPlumbingRunnerOverride.$current.withValue(runner) {
            try await body()
        }
    }

    /// Runs a read-only git command in the repository work tree.
    nonisolated static func gitPlumbingOutput(
        repository: ResolvedGitRepository,
        arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) -> String? {
        let result = (GitPlumbingRunnerOverride.current ?? SystemGitMetadataGitRunner()).run(
            arguments: arguments,
            in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true)
        )
        guard acceptedExitCodes.contains(result.exitCode) else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `HEAD` names the reftable compatibility stub rather than a real branch.
    nonisolated static func headNamesReftableStub(_ headContents: String) -> Bool {
        let trimmed = headContents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(branchPrefix) else { return false }
        let branch = String(trimmed.dropFirst(branchPrefix.count))
        return branch == reftableHeadBranchSentinel
    }

    /// Resolves the checked-out branch through git when `HEAD` is a reftable stub.
    nonisolated static func gitBranchNameViaPlumbing(repository: ResolvedGitRepository) -> String? {
        gitPlumbingOutput(
            repository: repository,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            acceptedExitCodes: [0]
        ).flatMap(normalizedBranchName)
    }

    /// Classifies `HEAD` through git when the on-disk stub is the reftable sentinel.
    nonisolated static func gitCheckedOutBranchViaPlumbing(
        repository: ResolvedGitRepository
    ) -> GitCheckedOutBranch {
        if let branch = gitBranchNameViaPlumbing(repository: repository) {
            return .branch(branch)
        }
        if gitCurrentCommitViaPlumbing(repository: repository) != nil {
            return .detached
        }
        return .unreadable
    }

    /// Builds a `HEAD` signature through git when loose refs cannot resolve the stub.
    nonisolated static func gitHeadSignatureViaPlumbing(repository: ResolvedGitRepository) -> String? {
        guard let symbolicRef = gitPlumbingOutput(
            repository: repository,
            arguments: ["symbolic-ref", "HEAD"],
            acceptedExitCodes: [0]
        ) else {
            return gitPlumbingOutput(
                repository: repository,
                arguments: ["rev-parse", "HEAD"],
                acceptedExitCodes: [0]
            )
        }
        let commit = gitPlumbingOutput(
            repository: repository,
            arguments: ["rev-parse", "HEAD"],
            acceptedExitCodes: [0]
        ) ?? ""
        return "\(symbolicRef)\n\(commit)"
    }

    /// Resolves `HEAD` to a commit SHA through git when loose refs are unavailable.
    nonisolated static func gitCurrentCommitViaPlumbing(repository: ResolvedGitRepository) -> String? {
        guard let value = gitPlumbingOutput(
            repository: repository,
            arguments: ["rev-parse", "HEAD"],
            acceptedExitCodes: [0]
        ) else {
            return nil
        }
        let normalized = value.lowercased()
        guard normalized.count == 40, normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return normalized
    }
}

/// Runs read-only git plumbing for ``GitMetadataService``.
protocol GitMetadataGitRunning: Sendable {
    func run(arguments: [String], in directory: URL) -> GitMetadataGitResult
}

struct GitMetadataGitResult: Sendable {
    let output: String
    let exitCode: Int32
}

struct SystemGitMetadataGitRunner: GitMetadataGitRunning {
    private static let maximumOutputByteCount = 4 * 1024
    private static let wallTimeLimit: TimeInterval = 5
    private static let pollInterval: TimeInterval = 0.01
    private static let processExitGraceLimit: TimeInterval = 2
    private static let sigkillGraceLimit: TimeInterval = 0.2

    func run(arguments: [String], in directory: URL) -> GitMetadataGitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return GitMetadataGitResult(output: "", exitCode: 127)
        }

        let readHandle = outputPipe.fileHandleForReading
        var collected = Data()
        let readDeadline = Date().addingTimeInterval(Self.wallTimeLimit)
        readLoop: while Date() < readDeadline {
            let remainingCapacity = Self.maximumOutputByteCount - collected.count
            switch readHandle.readAvailableData(maxLength: max(remainingCapacity, 1)) {
            case .success(.data(let chunk)):
                collected.append(chunk)
                if collected.count >= Self.maximumOutputByteCount {
                    process.terminate()
                    break readLoop
                }
            case .success(.endOfFile):
                break readLoop
            case .success(.wouldBlock):
                if !process.isRunning {
                    break readLoop
                }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            case .failure:
                break readLoop
            }
        }

        Self.terminateProcessIfRunning(process)
        guard Self.waitForProcessExit(process, deadline: Self.processExitGraceLimit) else {
            return GitMetadataGitResult(output: "", exitCode: 127)
        }

        let outputData = collected.prefix(Self.maximumOutputByteCount)
        guard let output = String(bytes: outputData, encoding: .utf8) else {
            return GitMetadataGitResult(output: "", exitCode: 127)
        }
        return GitMetadataGitResult(output: output, exitCode: process.terminationStatus)
    }

    private static func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    private static func waitForProcessExit(_ process: Process, deadline: TimeInterval) -> Bool {
        let exitDeadline = Date().addingTimeInterval(deadline)
        while process.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        guard process.isRunning else { return true }

        // `isRunning` ensures the pid still belongs to this Process before kill.
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(Self.sigkillGraceLimit)
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return !process.isRunning
    }
}

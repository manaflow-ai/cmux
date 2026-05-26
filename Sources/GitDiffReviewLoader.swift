import Foundation

nonisolated enum GitDiffReviewLoader {
    static func load(rootPath: String) async throws -> GitDiffReviewSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitDiffReviewLoadError.missingDirectory(rootPath)
        }

        let repositoryRoot = try await runGit(["-C", rootPath, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else {
            throw GitDiffReviewLoadError.notGitRepository(rootPath)
        }

        async let branch = gitBranchLabel(repositoryRoot: repositoryRoot)
        async let statusText = runGit(["-C", repositoryRoot, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        async let diffText = workingTreeDiff(repositoryRoot: repositoryRoot)
        let loadedBranch = await branch
        let loadedStatusText = try await statusText
        let loadedDiffText = try await diffText

        return GitDiffReviewSnapshot(
            repositoryRoot: repositoryRoot,
            branch: loadedBranch,
            files: GitDiffReviewParser.parse(diffText: loadedDiffText, statusText: loadedStatusText),
            loadedAt: Date()
        )
    }

    private static func gitBranchLabel(repositoryRoot: String) async -> String {
        let branch = try? await runGit(["-C", repositoryRoot, "branch", "--show-current"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            return branch
        }

        let head = try? await runGit(["-C", repositoryRoot, "rev-parse", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let head, !head.isEmpty {
            return head
        }

        return "HEAD"
    }

    private static func workingTreeDiff(repositoryRoot: String) async throws -> String {
        let hasHead = (try? await runGit(["-C", repositoryRoot, "rev-parse", "--verify", "HEAD"])) != nil
        guard hasHead else {
            return try await runGit(["-C", repositoryRoot, "diff", "--no-ext-diff", "--no-color", "--find-renames", "--cached", "--"])
        }

        return try await runGit(["-C", repositoryRoot, "diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD", "--"])
    }

    private static func runGit(_ arguments: [String]) async throws -> String {
        try Task.checkCancellation()

        let cancellationState = GitDiffProcessCancellationState()
        return try await withTaskCancellationHandler {
            try await runGitProcess(arguments, cancellationState: cancellationState)
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private static func runGitProcess(
        _ arguments: [String],
        cancellationState: GitDiffProcessCancellationState
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, newValue in newValue }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let termination = GitDiffProcessTerminationObserver()
        process.terminationHandler = { completedProcess in
            termination.finish(completedProcess.terminationStatus)
        }

        cancellationState.setProcess(process)

        async let outputData = readAllData(from: stdout.fileHandleForReading)
        async let errorData = readAllData(from: stderr.fileHandleForReading)

        do {
            try process.run()
        } catch {
            cancellationState.clear()
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            throw GitDiffReviewLoadError.commandFailed
        }

        let terminationStatus = await termination.value()
        cancellationState.clear()

        let output: String
        let errorOutput: String
        do {
            output = String(data: try await outputData, encoding: .utf8) ?? ""
            errorOutput = String(data: try await errorData, encoding: .utf8) ?? ""
        } catch is CancellationError {
            throw GitDiffReviewLoadError.cancelled
        } catch {
            throw GitDiffReviewLoadError.commandFailed
        }

        guard terminationStatus == 0 else {
            if errorOutput.contains("not a git repository") {
                throw GitDiffReviewLoadError.notGitRepository("")
            }
            throw GitDiffReviewLoadError.commandFailed
        }

        return output
    }

    private static func readAllData(from handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }
}

private final class GitDiffProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        let processToTerminate: Process?

        lock.lock()
        processToTerminate = process
        process = nil
        lock.unlock()

        if processToTerminate?.isRunning == true {
            processToTerminate?.terminate()
        }
    }
}

private final class GitDiffProcessTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var terminationStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        let continuationToResume: CheckedContinuation<Int32, Never>?

        lock.lock()
        if let continuation {
            continuationToResume = continuation
            self.continuation = nil
        } else {
            terminationStatus = status
            continuationToResume = nil
        }
        lock.unlock()

        continuationToResume?.resume(returning: status)
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            let statusToResume: Int32?

            lock.lock()
            if let terminationStatus {
                statusToResume = terminationStatus
            } else {
                statusToResume = nil
                self.continuation = continuation
            }
            lock.unlock()

            if let statusToResume {
                continuation.resume(returning: statusToResume)
            }
        }
    }
}

import Darwin
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
        let loadedBranch = try await branch
        let loadedStatusText = try await statusText
        let loadedDiffText = try await diffText

        return GitDiffReviewSnapshot(
            repositoryRoot: repositoryRoot,
            branch: loadedBranch,
            files: GitDiffReviewParser.parse(diffText: loadedDiffText, statusText: loadedStatusText),
            loadedAt: Date()
        )
    }

    private static func gitBranchLabel(repositoryRoot: String) async throws -> String {
        let branch = try await optionalGitOutput(["-C", repositoryRoot, "branch", "--show-current"])
        if let branch, !branch.isEmpty {
            return branch
        }

        let head = try await optionalGitOutput(["-C", repositoryRoot, "rev-parse", "--short", "HEAD"])
        if let head, !head.isEmpty {
            return head
        }

        return "HEAD"
    }

    private static func workingTreeDiff(repositoryRoot: String) async throws -> String {
        let hasHead = try await hasGitHead(repositoryRoot: repositoryRoot)
        guard hasHead else {
            return try await runGit(["-C", repositoryRoot, "diff", "--no-ext-diff", "--no-color", "--find-renames", "--cached", "--"])
        }

        return try await runGit(["-C", repositoryRoot, "diff", "--no-ext-diff", "--no-color", "--find-renames", "HEAD", "--"])
    }

    private static func optionalGitOutput(_ arguments: [String]) async throws -> String? {
        do {
            return try await runGit(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitDiffReviewLoadError.cancelled {
            throw GitDiffReviewLoadError.cancelled
        } catch is CancellationError {
            throw GitDiffReviewLoadError.cancelled
        } catch {
            return nil
        }
    }

    private static func hasGitHead(repositoryRoot: String) async throws -> Bool {
        do {
            _ = try await runGit(["-C", repositoryRoot, "rev-parse", "--verify", "HEAD"])
            return true
        } catch GitDiffReviewLoadError.cancelled {
            throw GitDiffReviewLoadError.cancelled
        } catch is CancellationError {
            throw GitDiffReviewLoadError.cancelled
        } catch {
            return false
        }
    }

    private static func runGit(_ arguments: [String]) async throws -> String {
        try Task.checkCancellation()

        let cancellationState = GitDiffProcessCancellationState()
        return try await withTaskCancellationHandler {
            try await runGitProcess(
                arguments,
                workingDirectoryPath: workingDirectoryPath(from: arguments),
                cancellationState: cancellationState
            )
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private static func runGitProcess(
        _ arguments: [String],
        workingDirectoryPath: String?,
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

        guard cancellationState.setProcess(process) else {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            throw GitDiffReviewLoadError.cancelled
        }

        async let outputData = readAllData(from: stdout.fileHandleForReading)
        async let errorData = readAllData(from: stderr.fileHandleForReading)

        do {
            try cancellationState.runProcessIfNotCancelled()
        } catch GitDiffReviewLoadError.cancelled {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            throw GitDiffReviewLoadError.cancelled
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
            if errorOutput.contains("not a git repository"),
               let workingDirectoryPath {
                throw GitDiffReviewLoadError.notGitRepository(workingDirectoryPath)
            }
            throw GitDiffReviewLoadError.commandFailed
        }

        return output
    }

    private static func workingDirectoryPath(from arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() where argument == "-C" {
            let pathIndex = index + 1
            guard pathIndex < arguments.count else { return nil }
            return arguments[pathIndex]
        }
        return nil
    }

    private static func readAllData(from handle: FileHandle) async throws -> Data {
        let reader = GitDiffPipeDataReader(handle: handle)
        return try await withTaskCancellationHandler {
            try await reader.readAllData()
        } onCancel: {
            reader.cancel()
        }
    }
}

private final class GitDiffPipeDataReader: @unchecked Sendable {
    private static let chunkSize = 64 * 1024

    private let handle: FileHandle
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completedResult: Result<Data, Error>?
    private var isCancelled = false
    private var hasStarted = false

    init(handle: FileHandle) {
        self.handle = handle
        self.fileDescriptor = handle.fileDescriptor
    }

    func readAllData() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resultToResume: Result<Data, Error>?
            let threadToStart: Thread?

            lock.lock()
            if let completedResult {
                resultToResume = completedResult
                threadToStart = nil
            } else if hasStarted {
                resultToResume = .failure(GitDiffReviewLoadError.commandFailed)
                threadToStart = nil
            } else {
                resultToResume = nil
                self.continuation = continuation
                hasStarted = true
                threadToStart = makeReaderThread()
            }
            lock.unlock()

            if let resultToResume {
                resume(continuation, with: resultToResume)
            } else {
                threadToStart?.start()
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()

        finish(.failure(CancellationError()))
        try? handle.close()
    }

    private func makeReaderThread() -> Thread {
        let thread = Thread {
            self.readToEndOfFileOnDedicatedThread()
        }
        thread.name = "cmux-code-review-pipe-reader"
        return thread
    }

    private func readToEndOfFileOnDedicatedThread() {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)

        while true {
            let byteCount = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, Self.chunkSize)
            }

            if byteCount > 0 {
                data.append(contentsOf: buffer[..<byteCount])
                continue
            }
            if byteCount == 0 {
                finishRead(data)
                return
            }

            if errno == EINTR {
                continue
            }
            finishReadFailure()
            return
        }
    }

    private func finishRead(_ data: Data) {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()

        if cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.success(data))
        }
    }

    private func finishReadFailure() {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()

        if cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(GitDiffReviewLoadError.commandFailed))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuationToResume: CheckedContinuation<Data, Error>?

        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        continuationToResume = continuation
        continuation = nil
        completedResult = result
        lock.unlock()

        guard let continuationToResume else { return }
        resume(continuationToResume, with: result)
    }

    private func resume(_ continuation: CheckedContinuation<Data, Error>, with result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class GitDiffProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func setProcess(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func runProcessIfNotCancelled() throws {
        lock.lock()
        guard !isCancelled, let process else {
            self.process = nil
            lock.unlock()
            throw GitDiffReviewLoadError.cancelled
        }

        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        let processToTerminate: Process?

        lock.lock()
        isCancelled = true
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

import Foundation

enum DiffReviewGitError: LocalizedError, Equatable, Sendable {
    case notGitRepository
    case commandFailed(DiffReviewGitFailureReason)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return String(localized: "diffReview.error.notGitRepository", defaultValue: "The selected workspace is not a git repository.")
        case .commandFailed(.diffUnavailable):
            return String(
                localized: "diffReview.error.diffUnavailable",
                defaultValue: "Could not load the selected comparison. Refresh Review or choose another base."
            )
        case .commandFailed(.hunkRevertFailed):
            return String(
                localized: "diffReview.error.hunkRevertFailed",
                defaultValue: "Could not revert that hunk. Refresh Review and try again."
            )
        case .commandFailed(.generic):
            return String(localized: "diffReview.error.gitFailed", defaultValue: "Git command failed.")
        }
    }
}

enum DiffReviewGitFailureReason: Equatable, Sendable {
    case generic
    case diffUnavailable
    case hunkRevertFailed
}

enum DiffReviewGitClient {
    static func loadSnapshot(directory: String, selectedTargetID: String) async throws -> DiffReviewSnapshot {
        try await Task.detached(priority: .utility) {
            try await loadSnapshotData(directory: directory, selectedTargetID: selectedTargetID)
        }.value
    }

    static func revertHunk(repositoryRoot: String, patch: String) async throws {
        try await Task.detached(priority: .utility) {
            do {
                _ = try await runGit(
                    in: repositoryRoot,
                    arguments: ["apply", "-R", "--index", "--whitespace=nowarn", "-"],
                    standardInput: patch,
                    acceptedStatuses: [0],
                    failureReason: .hunkRevertFailed
                )
                return
            } catch {
                // --index only works when the index and worktree both match the hunk.
                // Plain unstaged hunks fall back to a worktree apply, with a best-effort
                // cached apply for staged hunks that can still be represented safely.
            }

            _ = try await runGit(
                in: repositoryRoot,
                arguments: ["apply", "-R", "--whitespace=nowarn", "-"],
                standardInput: patch,
                acceptedStatuses: [0],
                failureReason: .hunkRevertFailed
            )
            _ = try? await runGit(
                in: repositoryRoot,
                arguments: ["apply", "-R", "--cached", "--whitespace=nowarn", "-"],
                standardInput: patch,
                acceptedStatuses: [0],
                failureReason: .hunkRevertFailed
            )
        }.value
    }

    private static func loadSnapshotData(directory: String, selectedTargetID: String) async throws -> DiffReviewSnapshot {
        let repositoryRootResult = try await runGit(
            in: directory,
            arguments: ["rev-parse", "--show-toplevel"],
            acceptedStatuses: [0, 128]
        )
        guard repositoryRootResult.status == 0 else {
            throw DiffReviewGitError.notGitRepository
        }
        let repositoryRoot = repositoryRootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else { throw DiffReviewGitError.notGitRepository }

        let currentBranch = try? await runGit(
            in: repositoryRoot,
            arguments: ["branch", "--show-current"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchesOutput = (try? await runGit(
            in: repositoryRoot,
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"]
        ).stdout) ?? ""
        let branches = branchesOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let selectedTarget = DiffReviewTarget.from(id: selectedTargetID, branches: branches)
        let hasHead = ((try? await runGit(
            in: repositoryRoot,
            arguments: ["rev-parse", "--verify", "HEAD"]
        )) != nil)
        let untrackedPaths = await fetchUntrackedPaths(repositoryRoot: repositoryRoot)
        let diffOutput = try await diffOutput(
            repositoryRoot: repositoryRoot,
            selectedTarget: selectedTarget,
            hasHead: hasHead,
            untrackedPaths: untrackedPaths
        )
        let files = DiffReviewPatchParser.parse(
            diffOutput,
            untrackedPaths: Set(untrackedPaths)
        )

        return DiffReviewSnapshot(
            repositoryRoot: repositoryRoot,
            currentBranch: currentBranch?.isEmpty == false ? currentBranch : nil,
            branches: branches,
            selectedTarget: selectedTarget,
            files: files,
            generatedAt: Date.now
        )
    }

    private static func diffOutput(
        repositoryRoot: String,
        selectedTarget: DiffReviewTarget,
        hasHead: Bool,
        untrackedPaths: [String]
    ) async throws -> String {
        let trackedDiffArguments: [String]
        switch selectedTarget {
        case .workingTree:
            trackedDiffArguments = hasHead
                ? ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3", "HEAD", "--"]
                : ["diff", "--no-ext-diff", "--no-color", "--find-renames", "--unified=3", "--"]
        case .branch(let branchName):
            let mergeBase = try await runGit(
                in: repositoryRoot,
                arguments: ["merge-base", branchName, "HEAD"],
                failureReason: .diffUnavailable
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mergeBase.isEmpty else {
                throw DiffReviewGitError.commandFailed(.diffUnavailable)
            }
            trackedDiffArguments = [
                "diff",
                "--no-ext-diff",
                "--no-color",
                "--find-renames",
                "--unified=3",
                mergeBase,
                "--",
            ]
        }

        let trackedOutput = try await runGit(
            in: repositoryRoot,
            arguments: trackedDiffArguments,
            acceptedStatuses: [0, 1],
            failureReason: .diffUnavailable
        ).stdout
        guard !untrackedPaths.isEmpty else {
            return trackedOutput
        }

        let untrackedOutput = await untrackedDiffOutput(
            repositoryRoot: repositoryRoot,
            untrackedPaths: untrackedPaths
        )

        if trackedOutput.isEmpty {
            return untrackedOutput
        }
        if untrackedOutput.isEmpty {
            return trackedOutput
        }
        return trackedOutput + "\n" + untrackedOutput
    }

    private static func untrackedDiffOutput(repositoryRoot: String, untrackedPaths: [String]) async -> String {
        let paths = Array(untrackedPaths.prefix(100))
        guard !paths.isEmpty else { return "" }

        let maxConcurrentDiffs = 8
        var outputs = Array<String?>(repeating: nil, count: paths.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            var nextPathIndex = 0
            var inFlightCount = 0

            func enqueueNextDiff() {
                guard nextPathIndex < paths.count else { return }
                let index = nextPathIndex
                let path = paths[index]
                nextPathIndex += 1
                inFlightCount += 1
                group.addTask {
                    let output = try? await runGit(
                        in: repositoryRoot,
                        arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", "--no-index", "--", "/dev/null", path],
                        acceptedStatuses: [0, 1]
                    ).stdout
                    return (index, output)
                }
            }

            while inFlightCount < maxConcurrentDiffs, nextPathIndex < paths.count {
                enqueueNextDiff()
            }

            while let (index, output) = await group.next() {
                inFlightCount -= 1
                outputs[index] = output
                enqueueNextDiff()
            }
        }
        return outputs.compactMap { $0 }.joined(separator: "\n")
    }

    private static func fetchUntrackedPaths(repositoryRoot: String) async -> [String] {
        guard let result = try? await runGit(
            in: repositoryRoot,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"]
        ) else {
            return []
        }
        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private struct GitCommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private final class GitProcessCancellation {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func register(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldCancel = cancelled
            lock.unlock()

            if shouldCancel, process.isRunning {
                process.terminate()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()

            if process?.isRunning == true {
                process?.terminate()
            }
        }

        func finish() {
            lock.lock()
            process = nil
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    private final class GitProcessCompletion {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private static func runGit(
        in directory: String,
        arguments: [String],
        standardInput: String? = nil,
        acceptedStatuses: Set<Int32> = [0],
        failureReason: DiffReviewGitFailureReason = .generic
    ) async throws -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        let cancellation = GitProcessCancellation()
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                async let outputData = readData(from: outputPipe.fileHandleForReading)
                async let errorData = readData(from: errorPipe.fileHandleForReading)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion = GitProcessCompletion(continuation)
                    var didCloseOutputWriters = false
                    func closeOutputWriters() {
                        guard !didCloseOutputWriters else { return }
                        didCloseOutputWriters = true
                        outputPipe.fileHandleForWriting.closeFile()
                        errorPipe.fileHandleForWriting.closeFile()
                    }

                    cancellation.register(process)
                    process.terminationHandler = { _ in
                        cancellation.finish()
                        completion.resume(.success(()))
                    }
                    do {
                        try process.run()
                        // Close parent write ends so async readers observe EOF after the child exits.
                        closeOutputWriters()
                        if cancellation.isCancelled, process.isRunning {
                            process.terminate()
                        }
                        if let standardInput, let inputPipe {
                            try inputPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
                        }
                        inputPipe?.fileHandleForWriting.closeFile()
                    } catch {
                        cancellation.finish()
                        closeOutputWriters()
                        inputPipe?.fileHandleForWriting.closeFile()
                        completion.resume(.failure(error))
                    }
                }
                let (output, error) = try await (outputData, errorData)

                if cancellation.isCancelled {
                    throw CancellationError()
                }

                return GitCommandResult(
                    status: process.terminationStatus,
                    stdout: String(data: output, encoding: .utf8) ?? "",
                    stderr: String(data: error, encoding: .utf8) ?? ""
                )
            } onCancel: {
                cancellation.cancel()
            }

            guard acceptedStatuses.contains(result.status) else {
                throw DiffReviewGitError.commandFailed(failureReason)
            }
            return result
        } catch let error as DiffReviewGitError {
            throw error
        } catch {
            throw DiffReviewGitError.commandFailed(.generic)
        }
    }

    private static func readData(from handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            data.append(byte)
        }
        return data
    }
}

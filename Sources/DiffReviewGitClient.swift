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
            _ = try await runGit(
                in: repositoryRoot,
                arguments: ["apply", "-R", "--whitespace=nowarn", "-"],
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
        let untrackedPaths = selectedTarget == .workingTree
            ? await fetchUntrackedPaths(repositoryRoot: repositoryRoot)
            : []
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
            trackedDiffArguments = [
                "diff",
                "--no-ext-diff",
                "--no-color",
                "--find-renames",
                "--unified=3",
                "\(branchName)...HEAD",
                "--",
            ]
        }

        let trackedOutput = try await runGit(
            in: repositoryRoot,
            arguments: trackedDiffArguments,
            acceptedStatuses: [0, 1],
            failureReason: .diffUnavailable
        ).stdout
        guard selectedTarget == .workingTree, !untrackedPaths.isEmpty else {
            return trackedOutput
        }

        var untrackedOutputs: [String] = []
        for path in untrackedPaths.prefix(100) {
            if let output = try? await runGit(
                in: repositoryRoot,
                arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", "--no-index", "--", "/dev/null", path],
                acceptedStatuses: [0, 1]
            ).stdout {
                untrackedOutputs.append(output)
            }
        }
        let untrackedOutput = untrackedOutputs.joined(separator: "\n")

        if trackedOutput.isEmpty {
            return untrackedOutput
        }
        if untrackedOutput.isEmpty {
            return trackedOutput
        }
        return trackedOutput + "\n" + untrackedOutput
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

        do {
            async let outputData = readData(from: outputPipe.fileHandleForReading)
            async let errorData = readData(from: errorPipe.fileHandleForReading)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume(returning: ())
                }
                do {
                    try process.run()
                    // Close parent write ends so async readers observe EOF after the child exits.
                    outputPipe.fileHandleForWriting.closeFile()
                    errorPipe.fileHandleForWriting.closeFile()
                    if let standardInput, let inputPipe {
                        inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                    }
                    inputPipe?.fileHandleForWriting.closeFile()
                } catch {
                    outputPipe.fileHandleForWriting.closeFile()
                    errorPipe.fileHandleForWriting.closeFile()
                    inputPipe?.fileHandleForWriting.closeFile()
                    continuation.resume(throwing: error)
                }
            }
            let (output, error) = try await (outputData, errorData)

            let result = GitCommandResult(
                status: process.terminationStatus,
                stdout: String(data: output, encoding: .utf8) ?? "",
                stderr: String(data: error, encoding: .utf8) ?? ""
            )
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

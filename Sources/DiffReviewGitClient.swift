import Foundation

enum DiffReviewGitError: LocalizedError, Equatable, Sendable {
    case notGitRepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGitRepository:
            return String(localized: "diffReview.error.notGitRepository", defaultValue: "The selected workspace is not a git repository.")
        case .commandFailed(let detail):
            return detail.isEmpty
                ? String(localized: "diffReview.error.gitFailed", defaultValue: "Git command failed.")
                : detail
        }
    }
}

enum DiffReviewGitClient {
    static func loadSnapshot(directory: String, selectedTargetID: String) async throws -> DiffReviewSnapshot {
        try await Task.detached(priority: .utility) {
            try loadSnapshotSync(directory: directory, selectedTargetID: selectedTargetID)
        }.value
    }

    static func revertHunk(repositoryRoot: String, patch: String) async throws {
        try await Task.detached(priority: .utility) {
            _ = try runGit(
                in: repositoryRoot,
                arguments: ["apply", "-R", "--whitespace=nowarn", "-"],
                standardInput: patch,
                acceptedStatuses: [0]
            )
        }.value
    }

    private static func loadSnapshotSync(directory: String, selectedTargetID: String) throws -> DiffReviewSnapshot {
        let repositoryRoot = try runGit(
            in: directory,
            arguments: ["rev-parse", "--show-toplevel"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else { throw DiffReviewGitError.notGitRepository }

        let currentBranch = try? runGit(
            in: repositoryRoot,
            arguments: ["branch", "--show-current"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchesOutput = (try? runGit(
            in: repositoryRoot,
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"]
        ).stdout) ?? ""
        let branches = branchesOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let selectedTarget = DiffReviewTarget.from(id: selectedTargetID, branches: branches)
        let hasHead = ((try? runGit(
            in: repositoryRoot,
            arguments: ["rev-parse", "--verify", "HEAD"]
        )) != nil)
        let untrackedPaths = selectedTarget == .workingTree
            ? fetchUntrackedPaths(repositoryRoot: repositoryRoot)
            : []
        let diffOutput = try diffOutput(
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
    ) throws -> String {
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

        let trackedOutput = try runGit(
            in: repositoryRoot,
            arguments: trackedDiffArguments,
            acceptedStatuses: [0, 1]
        ).stdout
        guard selectedTarget == .workingTree, !untrackedPaths.isEmpty else {
            return trackedOutput
        }

        let untrackedOutput = untrackedPaths.prefix(100).compactMap { path in
            try? runGit(
                in: repositoryRoot,
                arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", "--no-index", "--", "/dev/null", path],
                acceptedStatuses: [0, 1]
            ).stdout
        }.joined(separator: "\n")

        if trackedOutput.isEmpty {
            return untrackedOutput
        }
        if untrackedOutput.isEmpty {
            return trackedOutput
        }
        return trackedOutput + "\n" + untrackedOutput
    }

    private static func fetchUntrackedPaths(repositoryRoot: String) -> [String] {
        guard let result = try? runGit(
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
        acceptedStatuses: Set<Int32> = [0]
    ) throws -> GitCommandResult {
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
            try process.run()
            if let standardInput, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            }
            inputPipe?.fileHandleForWriting.closeFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let result = GitCommandResult(
                status: process.terminationStatus,
                stdout: String(data: outputData, encoding: .utf8) ?? "",
                stderr: String(data: errorData, encoding: .utf8) ?? ""
            )
            guard acceptedStatuses.contains(result.status) else {
                throw DiffReviewGitError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result
        } catch let error as DiffReviewGitError {
            throw error
        } catch {
            throw DiffReviewGitError.commandFailed(error.localizedDescription)
        }
    }
}

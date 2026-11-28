import Foundation

/// Loads a bounded, non-locking snapshot for a local Git repository.
public struct GitGraphService: Sendable {
    public static let maximumCommitCount = 500
    private static let requestedCommitCount = maximumCommitCount + 1
    private static let maximumLogOutputByteCount = 4 * 1_024 * 1_024
    private let runner: any WorkspaceChangesGitRunning

    public init() {
        runner = SystemWorkspaceChangesGitRunner()
    }

    init(runner: any WorkspaceChangesGitRunning) {
        self.runner = runner
    }

    public func snapshot(forDirectory directory: String) async throws -> GitGraphSnapshot {
        let runner = self.runner
        return try await Task.detached(priority: .userInitiated) {
            try Self.load(directory: directory, runner: runner)
        }.value
    }

    private static func load(
        directory: String,
        runner: any WorkspaceChangesGitRunning
    ) throws -> GitGraphSnapshot {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let rootResult = try runner.run(
            arguments: ["rev-parse", "--show-toplevel"],
            in: directoryURL,
            maximumOutputByteCount: 16 * 1_024
        )
        guard rootResult.exitCode == 0,
              let root = String(data: rootResult.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else {
            throw GitGraphServiceError.notRepository
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)

        let branchResult = try runner.run(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: rootURL,
            maximumOutputByteCount: 16 * 1_024
        )
        let branch = branchResult.exitCode == 0
            ? String(data: branchResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let headResult = try runner.run(
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"],
            in: rootURL,
            maximumOutputByteCount: 128
        )
        let headOID = headResult.exitCode == 0
            ? String(data: headResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let statusResult = try runner.run(
            arguments: [
                "status", "--porcelain=v1", "-z", "--ignore-submodules=dirty", "--no-renames",
            ],
            in: rootURL,
            maximumOutputByteCount: 1
        )
        let isDirty = !statusResult.output.isEmpty

        let logResult = try runner.run(
            arguments: [
                "log",
                "--all",
                "--date-order",
                "--decorate=full",
                "--no-color",
                "--no-show-signature",
                "--max-count=\(requestedCommitCount)",
                "--format=%H%x00%P%x00%D%x00%an%x00%aI%x00%s%x00",
            ],
            in: rootURL,
            maximumOutputByteCount: maximumLogOutputByteCount
        )
        guard logResult.exitCode == 0 || logResult.standardOutputWasTruncated else {
            throw GitGraphServiceError.commandFailed
        }
        let parsedCommits = GitGraphSnapshotParser().commits(from: logResult.output)
        let commits = Array(parsedCommits.prefix(maximumCommitCount))
        let truncation: GitGraphTruncation
        if logResult.standardOutputWasTruncated {
            truncation = .outputLimit
        } else if parsedCommits.count > maximumCommitCount {
            truncation = .commitLimit
        } else {
            truncation = .none
        }
        return GitGraphSnapshot(
            repositoryRoot: root,
            branch: branch?.nilIfEmpty,
            headOID: headOID?.nilIfEmpty,
            isDirty: isDirty,
            rows: GitGraphLayout().rows(for: commits),
            truncation: truncation
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

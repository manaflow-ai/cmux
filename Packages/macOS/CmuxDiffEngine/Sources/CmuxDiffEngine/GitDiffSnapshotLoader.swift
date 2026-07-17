import CryptoKit
import Foundation

/// Loads tracked Git metadata in batches and merges in untracked regular files.
struct GitDiffSnapshotLoader: Sendable {
    private static let patchByteLimit = 1_048_576
    private static let changedLineLimit = 3_000

    let commands: GitCommandExecutor
    let repositoryRoot: String

    func load(
        base: ResolvedDiffBase,
        ignoreWhitespace: Bool,
        pathspecs: [String] = []
    ) async throws -> GitDiffSnapshot {
        let whitespace = ignoreWhitespace ? ["-w"] : []
        let common = [
            "--no-pager", "diff", "--no-color", "--no-ext-diff",
            "--find-renames", "--find-copies-harder",
        ] + whitespace
        let suffix = [base.object, "--"] + pathspecs

        async let rawOutput = commands.run(common + ["--raw", "-z"] + suffix)
        async let numstatOutput = commands.run(common + ["--numstat", "-z"] + suffix)
        async let patchOutput = commands.run(common + ["--binary", "--full-index", "--patch", "-z"] + suffix)
        async let untrackedOutput = commands.run(
            ["ls-files", "--others", "--exclude-standard", "-z", "--"] + pathspecs
        )

        let parser = GitOutputParser()
        let changes = parser.rawChanges(try await rawOutput ?? "")
        let numstats = parser.numstats(try await numstatOutput ?? "")
        let patches = parser.patchSections(try await patchOutput ?? "")
        let trackedFiles = numstats.enumerated().map { index, numstat in
            let change = changes.first { record in
                record.path == numstat.path &&
                    (numstat.oldPath == nil || numstat.oldPath == record.oldPath)
            }
            let patch = index < patches.count ? patches[index] : Data()
            return makeFile(
                path: numstat.path,
                oldPath: change?.oldPath ?? numstat.oldPath,
                status: change?.status ?? .modified,
                additions: numstat.additions,
                deletions: numstat.deletions,
                isBinary: numstat.isBinary,
                patch: patch
            )
        }

        let reader = WorkingTreeFileReader(repositoryRoot: repositoryRoot)
        let untrackedPaths = (try await untrackedOutput ?? "")
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var untrackedFiles: [GitDiffFile] = []
        untrackedFiles.reserveCapacity(untrackedPaths.count)
        for path in untrackedPaths where !trackedFiles.contains(where: { $0.summary.path == path }) {
            guard let data = try reader.regularFileData(path: path) else { continue }
            let generated = reader.untrackedPatch(path: path, data: data)
            untrackedFiles.append(makeFile(
                path: path,
                oldPath: nil,
                status: .untracked,
                additions: generated.additions,
                deletions: 0,
                isBinary: generated.isBinary,
                patch: generated.patch
            ))
        }
        return GitDiffSnapshot(base: base, files: trackedFiles + untrackedFiles)
    }

    private func makeFile(
        path: String,
        oldPath: String?,
        status: DiffFileStatus,
        additions: Int,
        deletions: Int,
        isBinary: Bool,
        patch: Data
    ) -> GitDiffFile {
        let digest = SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined()
        let isLarge = additions + deletions > Self.changedLineLimit || patch.count > Self.patchByteLimit
        return GitDiffFile(
            summary: DiffFileSummary(
                path: path,
                oldPath: oldPath,
                status: status,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary,
                isLarge: isLarge,
                patchDigest: digest
            ),
            patch: patch
        )
    }
}

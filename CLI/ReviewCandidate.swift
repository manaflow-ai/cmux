import Foundation
import CryptoKit

/// Frozen candidate content and comparison material for one read-only review.
struct ReviewCandidate {
    let repository: String
    let directory: URL
    let candidateDirectory: URL
    let source: [String: Any]
    let patch: String
    let rules: String

    init(repository: String, base: String, directory: URL) throws {
        self.repository = repository
        self.directory = directory
        candidateDirectory = directory.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)

        let head = try Self.git(repository, ["rev-parse", "--verify", "HEAD^{commit}"])
        let baseSHA = try Self.git(repository, ["rev-parse", "--verify", "--end-of-options", "\(base)^{commit}"])
        let index = directory.appendingPathComponent("index").path
        _ = try Self.git(repository, ["read-tree", head], index: index)
        _ = try Self.git(repository, ["add", "--all", "--", "."], index: index)
        let tree = try Self.git(repository, ["write-tree"], index: index)
        let headTree = try Self.git(repository, ["rev-parse", "\(head)^{tree}"])
        patch = try Self.git(repository, ["diff", "--no-ext-diff", "--no-textconv", "--binary", baseSHA, tree, "--"])
        let rulePaths = try Self.git(repository, ["ls-tree", "-r", "--name-only", baseSHA, "--", "AGENTS.md", "CLAUDE.md", ".github/review-bot-rules"])
            .split(separator: "\n").map(String.init)
        rules = try rulePaths.map { path in
            "\(path):\n" + (try Self.git(repository, ["show", "\(baseSHA):\(path)"]))
        }.joined(separator: "\n\n")
        let commonDirectory = try Self.git(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let repositoryID = "local:" + SHA256.hash(data: Data(commonDirectory.utf8)).map { String(format: "%02x", $0) }.joined()
        source = [
            "repository_id": repositoryID,
            "base_sha": baseSHA,
            "head_sha": head,
            "tree_sha": tree,
            "working_tree_dirty": tree != headTree,
            "patch_sha256": SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
        ]
        // The adapter receives an immutable diff and rules, with tools disabled.
        // Use an empty Git root so candidate-controlled hooks, configuration,
        // symlinks, and agent instructions are never loaded by the reviewer.
        _ = try Self.git(repository, ["init", "--quiet", "--template=", candidateDirectory.path])
    }

    /// A temporary index captures tracked and untracked content without changing the real index.
    static func git(_ repository: String, _ arguments: [String], index: String? = nil) throws -> String {
        var environmentArguments = [
            "-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_COMMON_DIR",
            "-u", "GIT_INDEX_FILE", "-u", "GIT_OBJECT_DIRECTORY", "-u", "GIT_ALTERNATE_OBJECT_DIRECTORIES"
        ]
        if let index { environmentArguments.append("GIT_INDEX_FILE=\(index)") }
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: environmentArguments + ["git", "-C", repository] + arguments,
            timeout: 30
        )
        guard result.status == 0, !result.timedOut else {
            throw CLIError(message: String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string("cli.review.error.source", defaultValue: "Unable to capture review source: %@"),
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

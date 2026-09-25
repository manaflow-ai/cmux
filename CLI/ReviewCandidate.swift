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
        // Disable every configured filter, including process filters. Merely clearing
        // inherited GIT_* variables does not neutralize repository-local configuration.
        let filterKeys = (try? Self.git(repository, ["config", "--null", "--name-only", "--get-regexp", "^filter\\."])) ?? ""
        let filters = Set(filterKeys.split(separator: "\0").compactMap { key -> String? in
            guard let suffix = key.lastIndex(of: ".") else { return nil }
            return String(key[..<suffix])
        })
        let filterOverrides = filters.sorted().flatMap { filter in
            ["-c", "\(filter).clean=", "-c", "\(filter).smudge=", "-c", "\(filter).process=", "-c", "\(filter).required=false"]
        }
        _ = try Self.git(repository, filterOverrides + ["add", "--all", "--", "."], index: index)
        let tree = try Self.git(repository, ["write-tree"], index: index)
        let headTree = try Self.git(repository, ["rev-parse", "\(head)^{tree}"])
        let patchURL = directory.appendingPathComponent("patch.diff")
        _ = try Self.git(repository, ["diff", "--no-ext-diff", "--no-textconv", "--binary", "--output=\(patchURL.path)", baseSHA, tree, "--"])
        let patchAttributes = try FileManager.default.attributesOfItem(atPath: patchURL.path)
        guard let patchSize = patchAttributes[.size] as? NSNumber, patchSize.intValue <= 1_048_576 else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.review.error.diffTooLarge",
                defaultValue: "The review diff is too large. Choose a narrower base revision."
            ))
        }
        patch = try String(contentsOf: patchURL, encoding: .utf8)
        let rulePaths = try Self.git(repository, ["ls-tree", "-r", "-z", "--name-only", baseSHA], trim: false)
            .split(separator: "\0").map(String.init).filter { path in
                path.hasPrefix(".github/review-bot-rules/")
                    || path.split(separator: "/").last.map { $0 == "AGENTS.md" || $0 == "CLAUDE.md" } == true
            }
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

    /// Git environment variables can redirect repository discovery or configure filters.
    /// Reviews must snapshot the caller's explicit repository, never inherited hook state.
    static func gitEnvironmentArguments() -> [String] {
        ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("GIT_") }
            .sorted()
            .flatMap { ["-u", $0] }
    }

    /// A temporary index captures tracked and untracked content without changing the real index.
    static func git(_ repository: String, _ arguments: [String], index: String? = nil, trim: Bool = true) throws -> String {
        var environmentArguments = Self.gitEnvironmentArguments()
        if let index { environmentArguments.append("GIT_INDEX_FILE=\(index)") }
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: environmentArguments + [
                "git", "--no-optional-locks", "-c", "core.hooksPath=/dev/null",
                "-c", "core.fsmonitor=false", "-C", repository
            ] + arguments,
            timeout: 30
        )
        guard result.status == 0, !result.timedOut else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.review.error.source",
                defaultValue: "Unable to capture review source."
            ))
        }
        return trim ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdout
    }
}

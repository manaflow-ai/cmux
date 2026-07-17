import CmuxFoundation
import Foundation

extension ChangesEngine {
    /// Resolves the merge base between `HEAD` and the repository's default branch.
    ///
    /// The returned ``ChangesBase`` is concrete and can be passed directly to
    /// ``summary(repoRoot:base:ignoreWhitespace:)`` or
    /// ``fileDiff(repoRoot:base:path:oldPath:cursor:ignoreWhitespace:)``.
    ///
    /// - Parameters:
    ///   - repoRoot: The repository root directory.
    ///   - defaultBranch: An explicit default-branch ref, or `nil` to use repository heuristics.
    /// - Returns: A concrete merge-base reference.
    /// - Throws: ``ChangesEngineError/defaultBranchNotFound`` when no supported default exists.
    public func branchBase(repoRoot: String, defaultBranch: String? = nil) async throws -> ChangesBase {
        guard let head = try? await gitSingleLine(repoRoot: repoRoot, arguments: [
            "rev-parse", "--verify", "HEAD^{commit}",
        ]) else {
            return .ref(Self.emptyTreeHash)
        }

        let baseBranch: String
        if let defaultBranch {
            let trimmed = defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ChangesEngineError.invalidBase(defaultBranch) }
            baseBranch = trimmed
        } else {
            baseBranch = try await defaultBranchRef(repoRoot: repoRoot)
        }
        let mergeBase = try await gitSingleLine(repoRoot: repoRoot, arguments: [
            "merge-base", head, baseBranch,
        ])
        return .ref(mergeBase)
    }

    /// Resolves a starting directory to its canonical Git repository root.
    /// - Parameter directory: A directory inside a local Git working tree.
    /// - Returns: The standardized, symlink-resolved repository root path.
    /// - Throws: ``ChangesEngineError/gitFailed(_:)`` when the directory is not in a repository.
    public func repositoryRoot(startingAt directory: String) async throws -> String {
        let root = try await gitSingleLine(
            repoRoot: directory,
            arguments: ["rev-parse", "--show-toplevel"]
        )
        return URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    func resolveBase(repoRoot: String, base: ChangesBase) async throws -> ResolvedChangesBase {
        switch base {
        case .workingTree:
            if let head = try? await gitSingleLine(repoRoot: repoRoot, arguments: [
                "rev-parse", "--verify", "HEAD^{commit}",
            ]) {
                return ResolvedChangesBase(
                    diffRef: head,
                    info: ChangesBaseInfo(kind: .workingTree, resolvedRef: head, describe: "HEAD")
                )
            }
            return ResolvedChangesBase(
                diffRef: Self.emptyTreeHash,
                info: ChangesBaseInfo(
                    kind: .workingTree,
                    resolvedRef: Self.emptyTreeHash,
                    describe: "empty-tree"
                )
            )
        case let .ref(ref):
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let tree = try? await gitSingleLine(repoRoot: repoRoot, arguments: [
                      "rev-parse", "--verify", "\(trimmed)^{tree}",
                  ]) else {
                throw ChangesEngineError.invalidBase(ref)
            }
            return ResolvedChangesBase(
                diffRef: tree,
                info: ChangesBaseInfo(kind: .ref, resolvedRef: tree, describe: trimmed)
            )
        }
    }

    func gitDiffArguments(
        baseRef: String,
        ignoreWhitespace: Bool,
        options: [String],
        paths: [String] = []
    ) -> [String] {
        var arguments = [
            "diff", "-M", "-C", "--find-copies-harder", "--no-color", "--no-ext-diff",
        ]
        if ignoreWhitespace {
            arguments.append("-w")
        }
        arguments.append(contentsOf: options)
        arguments.append(baseRef)
        arguments.append("--")
        arguments.append(contentsOf: paths)
        return arguments
    }

    func runGit(repoRoot: String, arguments: [String]) async throws -> String {
        let result = await commandRunner.run(
            directory: repoRoot,
            executable: "/usr/bin/git",
            arguments: ["-c", "core.quotepath=false", "--literal-pathspecs"] + arguments,
            timeout: nil
        )
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let stdout = result.stdout else {
            let detail = result.executionError
                ?? result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "git exited with status \(result.exitStatus.map(String.init) ?? "unknown")"
            throw ChangesEngineError.gitFailed(detail)
        }
        return stdout
    }

    func gitSingleLine(repoRoot: String, arguments: [String]) async throws -> String {
        let output = try await runGit(repoRoot: repoRoot, arguments: arguments)
        guard let line = output.split(whereSeparator: \.isNewline).first.map(String.init),
              !line.isEmpty else {
            throw ChangesEngineError.gitFailed("git returned no object name")
        }
        return line
    }

    func defaultBranchRef(repoRoot: String) async throws -> String {
        if let originHead = try? await gitSingleLine(repoRoot: repoRoot, arguments: [
            "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
        ]) {
            return originHead
        }
        for candidate in ["origin/main", "origin/master", "upstream/main", "upstream/master", "main", "master"] {
            if (try? await gitSingleLine(repoRoot: repoRoot, arguments: [
                "rev-parse", "--verify", "\(candidate)^{commit}",
            ])) != nil {
                return candidate
            }
        }
        if let upstream = try? await gitSingleLine(repoRoot: repoRoot, arguments: [
            "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
        ]) {
            return upstream
        }
        throw ChangesEngineError.defaultBranchNotFound
    }

    func validatedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ChangesEngineError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ChangesEngineError.invalidPath(path)
        }
        return path
    }

    func fileURL(repoRoot: String, path: String) throws -> URL {
        let path = try validatedRelativePath(path)
        return URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
    }
}

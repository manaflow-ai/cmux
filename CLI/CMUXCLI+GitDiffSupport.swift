import Darwin
import Foundation


// MARK: - Git Plumbing for Diff Generation
extension CMUXCLI {
    private func currentGitRepoRoot() throws -> String {
        try gitRepoRoot(startingAt: FileManager.default.currentDirectoryPath)
    }

    func gitRepoRootForDiff(_ context: DiffSourceContext) throws -> String {
        guard let repoRoot = context.repoRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            return try currentGitRepoRoot()
        }
        return try gitRepoRoot(startingAt: repoRoot)
    }

    func gitRepoRoot(startingAt directory: String) throws -> String {
        do {
            return try standardizedDiffSourcePath(gitSingleLine(["rev-parse", "--show-toplevel"], in: directory))
        } catch {
            throw CLIError(message: "cmux diff git sources require a git repository")
        }
    }

    func gitBranchDiffBaseRef(in repoRoot: String) throws -> String {
        if let originHead = try? gitSingleLine(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoRoot),
           !originHead.isEmpty {
            return originHead
        }
        for candidate in ["origin/main", "origin/master", "upstream/main", "upstream/master", "main", "master"] {
            if (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: repoRoot)) != nil {
                return candidate
            }
        }
        if let upstream = try? gitSingleLine(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repoRoot),
           !upstream.isEmpty {
            return upstream
        }
        throw CLIError(message: "Unable to find a branch diff base. Set an upstream branch or create origin/main.")
    }

    func resolvedGitBranchDiffBaseRef(_ rawBaseRef: String?, in repoRoot: String) throws -> String {
        guard let rawBaseRef,
              !rawBaseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try gitBranchDiffBaseRef(in: repoRoot)
        }
        let baseRef = rawBaseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? gitStdout(["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"], in: repoRoot)) != nil else {
            throw CLIError(message: "Branch diff base not found in repository: \(baseRef)")
        }
        return baseRef
    }

    func gitSingleLine(_ arguments: [String], in directory: String) throws -> String {
        let output = try gitStdout(arguments, in: directory)
        guard let line = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            throw CLIError(message: "git returned empty output for \(arguments.joined(separator: " "))")
        }
        return line
    }

    func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard result.status == 0 else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    func gitDiffPatchArguments(_ tail: [String]) -> [String] {
        ["diff", "--no-ext-diff", "--no-color", "--binary"] + tail
    }

    func gitStdout(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32>
    ) throws -> String {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    private func gitStdoutData(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = 60,
        allowedExitStatuses: Set<Int32> = [0]
    ) throws -> Data {
        let result = CLIProcessRunner.runProcessData(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", directory] + arguments,
            timeout: timeout
        )
        if result.timedOut {
            throw CLIError(message: "git \(arguments.joined(separator: " ")) timed out")
        }
        guard allowedExitStatuses.contains(result.status) else {
            let command = (["git"] + arguments).joined(separator: " ")
            throw CLIError(message: "\(command) failed with status \(result.status)")
        }
        return result.stdout
    }

    func gitUntrackedPaths(in repoRoot: String) throws -> [String] {
        let output = try gitStdout(["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot)
        return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    func gitUntrackedPatchSinceBaseline(
        record: CMUXAgentTurnDiffBaselineRecord,
        in repoRoot: String,
        storePath: String
    ) throws -> String {
        let baselinePaths = Set(record.untrackedPaths ?? [])
        let baselineHashes = record.untrackedPathHashes ?? [:]
        let currentPaths = try gitUntrackedPaths(in: repoRoot)
        let currentPathSet = Set(currentPaths)
        var patches: [String] = []
        for path in currentPaths {
            guard baselinePaths.contains(path) else {
                patches.append(try gitAddedUntrackedPatch(path: path, in: repoRoot))
                continue
            }
            guard let baselineHash = baselineHashes[path] else {
                continue
            }
            guard try gitUntrackedPathHash(path, in: repoRoot) != baselineHash else {
                continue
            }
            if let baselineFileURL = agentTurnDiffBaselineSnapshotFileURL(
                path: path,
                record: record,
                storePath: storePath
            ), let patch = try gitChangedUntrackedPatch(path: path, baselineFileURL: baselineFileURL, in: repoRoot) {
                patches.append(patch)
            } else if let patch = try gitChangedUntrackedPatchFromGitObject(
                path: path,
                baselineHash: baselineHash,
                in: repoRoot
            ) {
                patches.append(patch)
            }
        }
        for path in baselinePaths.subtracting(currentPathSet).sorted() {
            guard !repoPathExists(path, in: repoRoot) else {
                continue
            }
            guard let baselineHash = baselineHashes[path] else {
                continue
            }
            let patch: String?
            if let baselineFileURL = agentTurnDiffBaselineSnapshotFileURL(
                path: path,
                record: record,
                storePath: storePath
            ) {
                patch = try gitDeletedUntrackedPatch(path: path, baselineFileURL: baselineFileURL)
            } else {
                patch = try gitDeletedUntrackedPatchFromGitObject(path: path, baselineHash: baselineHash, in: repoRoot)
            }
            guard let patch else { continue }
            patches.append(patch)
        }
        return joinedGitDiffPatches(patches)
    }

    private func gitAddedUntrackedPatch(path: String, in repoRoot: String) throws -> String {
        try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "/dev/null", path]),
            in: repoRoot,
            allowedExitStatuses: [0, 1]
        )
    }

    private func gitChangedUntrackedPatch(
        path: String,
        baselineFileURL: URL,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: baselineFileURL.path) else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let baselineFile = tempRoot
            .appendingPathComponent("baseline", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        let currentFile = tempRoot
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: baselineFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: baselineFileURL, to: baselineFile)
        guard let currentURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot) else {
            return nil
        }
        try FileManager.default.copyItem(
            at: currentURL,
            to: currentFile
        )

        let patch = try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "baseline/\(path)", "current/\(path)"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
        return rewriteChangedUntrackedPatch(patch)
    }

    private func gitChangedUntrackedPatchFromGitObject(
        path: String,
        baselineHash: String,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        let objectCheck = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "cat-file", "-e", "\(baselineHash)^{blob}"],
            timeout: 30
        )
        guard !objectCheck.timedOut, objectCheck.status == 0 else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let baselineFile = tempRoot
            .appendingPathComponent("baseline", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        let currentFile = tempRoot
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: baselineFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: currentFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let baselineContent = try gitStdoutData(["cat-file", "blob", baselineHash], in: repoRoot)
        try baselineContent.write(to: baselineFile, options: .atomic)
        guard let currentURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot) else {
            return nil
        }
        try FileManager.default.copyItem(
            at: currentURL,
            to: currentFile
        )

        let patch = try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", "baseline/\(path)", "current/\(path)"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
        return rewriteChangedUntrackedPatch(patch)
    }

    private func gitDeletedUntrackedPatch(
        path: String,
        baselineFileURL: URL
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: baselineFileURL.path) else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempPathURL.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: baselineFileURL, to: tempPathURL.file)
        return try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", path, "/dev/null"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
    }

    private func gitDeletedUntrackedPatchFromGitObject(
        path: String,
        baselineHash: String,
        in repoRoot: String
    ) throws -> String? {
        guard let tempPathURL = safeTemporaryGitPathURL(relativePath: path) else {
            return nil
        }
        let objectCheck = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "cat-file", "-e", "\(baselineHash)^{blob}"],
            timeout: 30
        )
        guard !objectCheck.timedOut, objectCheck.status == 0 else {
            return nil
        }

        let tempRoot = tempPathURL.root
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempPathURL.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = try gitStdoutData(["cat-file", "blob", baselineHash], in: repoRoot)
        try content.write(to: tempPathURL.file, options: .atomic)
        return try gitStdout(
            gitDiffPatchArguments(["--no-index", "--", path, "/dev/null"]),
            in: tempRoot.path,
            allowedExitStatuses: [0, 1]
        )
    }

    private func rewriteChangedUntrackedPatch(_ patch: String) -> String {
        patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)
                if line.hasPrefix("diff --git ") {
                    replaceFirstOccurrence(in: &line, of: "a/baseline/", with: "a/")
                    replaceFirstOccurrence(in: &line, of: "b/current/", with: "b/")
                } else if line.hasPrefix("--- ") {
                    replaceFirstOccurrence(in: &line, of: "a/baseline/", with: "a/")
                } else if line.hasPrefix("+++ ") {
                    replaceFirstOccurrence(in: &line, of: "b/current/", with: "b/")
                }
                return line
            }
            .joined(separator: "\n")
    }

    private func replaceFirstOccurrence(in line: inout String, of target: String, with replacement: String) {
        guard let range = line.range(of: target) else { return }
        line.replaceSubrange(range, with: replacement)
    }

    private func safeTemporaryGitPathURL(relativePath: String) -> (root: URL, file: URL)? {
        guard let components = safeRelativePathComponents(relativePath) else {
            return nil
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-untracked-\(UUID().uuidString)", isDirectory: true)
        let file = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        return (root, file)
    }

    private func repoPathExists(_ relativePath: String, in repoRoot: String) -> Bool {
        guard let url = safeRepoPathURL(relativePath: relativePath, repoRoot: repoRoot) else {
            return true
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func safeRepoPathURL(relativePath: String, repoRoot: String) -> URL? {
        guard let components = safeRelativePathComponents(relativePath) else {
            return nil
        }
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let url = components
            .reduce(root) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return url
    }

    func safeRelativePathComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

}

import Foundation
import CryptoKit

/// Stateless wrapper for git plumbing operations used by the per-turn diff snapshotting.
/// Uses /usr/bin/git shell-out (matches existing pattern in Sources/FileExplorerStore.swift:958).
///
/// All cmux-owned tree/commit objects are written into a per-(workspace, repo)
/// object store under `~/Library/Application Support/cmux/diff-state/...`,
/// NEVER into the user's `<repo>/.git/objects/`. The user's objects remain
/// readable via `GIT_ALTERNATE_OBJECT_DIRECTORIES` so HEAD-relative diffs still
/// work. We never call `git update-ref` against the user's repo — baseline
/// tree SHAs are tracked in-memory by `TurnCheckpointManager`.
enum TurnCheckpointStore {
    enum Error: Swift.Error {
        case gitFailed(stderr: String, exitCode: Int32)
        case unexpectedOutput(String)
    }

    // MARK: - Path helpers

    static func gitCommonDir(for worktree: String) -> String? {
        try? runGit(in: worktree, arguments: ["rev-parse", "--git-common-dir"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walk up from `path` looking for the nearest ancestor containing a `.git`
    /// directory or file (the latter for worktrees / submodules). Returns the
    /// containing directory path, or `nil` if no ancestor has `.git`.
    /// Stops at the filesystem root and never crosses outside the user's tree.
    static func gitRoot(containing path: String) -> String? {
        let fm = FileManager.default
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var current = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        // Hard cap at 64 ancestors to defend against pathological loops.
        for _ in 0..<64 {
            let candidate = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: candidate.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            // deletingLastPathComponent on "/" returns "/" — bail when we stop moving.
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - cmux-owned object store

    /// First 16 hex chars of SHA-256(repoRoot.absolutePath).
    /// Stable per repo path; safe to use as a directory name.
    static func repoHash(for repoRoot: String) -> String {
        let data = Data(repoRoot.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Returns `<HOME>/Library/Application Support/cmux/diff-state/<wsId>/<repo-hash>/objects/`.
    /// Creates the directory tree (and the parent `info`/`pack` dirs git needs)
    /// on first call. Logs the path once per (ws, repo) when DEBUG.
    static func diffStateDirectory(workspaceId: UUID, repoRoot: String) -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let hash = repoHash(for: repoRoot)
        let objectsDir = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-state", isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)

        let alreadyExisted = fm.fileExists(atPath: objectsDir.path)
        if !alreadyExisted {
            try? fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
            // git's loose-object writer needs an `info/` and `pack/` next to
            // `objects/` in the alternate; create them so writes don't ENOENT.
            try? fm.createDirectory(
                at: objectsDir.appendingPathComponent("info", isDirectory: true),
                withIntermediateDirectories: true
            )
            try? fm.createDirectory(
                at: objectsDir.appendingPathComponent("pack", isDirectory: true),
                withIntermediateDirectories: true
            )
            #if DEBUG
            cmuxDebugLog("turn-diff: cmux object store path=\(objectsDir.path)")
            #endif
        }
        return objectsDir
    }

    /// Best-effort: remove the entire workspace's diff-state directory.
    /// Called from `TurnCheckpointManager.stop()` to keep the on-disk footprint
    /// tidy across re-attaches.
    static func removeDiffStateDirectory(workspaceId: UUID) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-state", isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString.lowercased(), isDirectory: true)
        try? fm.removeItem(at: dir)
    }

    // MARK: - Persistent baseline (per repo)

    /// Returns `<HOME>/Library/Application Support/cmux/diff-state/<wsId>/<repo-hash>/baseline.txt`.
    /// Sibling of the `objects/` dir produced by `diffStateDirectory(workspaceId:repoRoot:)`.
    /// Holds a single 40-char tree SHA — the per-repo "frozen at start of last turn"
    /// baseline. Persisted so cmux restarts don't fall through to Tier 2 (HEAD diff)
    /// on the first turn after cold start.
    static func baselineFileURL(workspaceId: UUID, repoRoot: String) -> URL {
        // diffStateDirectory returns `.../objects/` — the baseline file is its sibling.
        return diffStateDirectory(workspaceId: workspaceId, repoRoot: repoRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("baseline.txt", isDirectory: false)
    }

    /// Sibling of `baseline.txt`. Records the absolute repo path so we can
    /// reconstruct the `[repoPath: tree]` dict on cold start (the dir name is
    /// just a SHA-256 hash of the repo path, which we can't invert).
    private static func repoPathFileURL(workspaceId: UUID, repoRoot: String) -> URL {
        return diffStateDirectory(workspaceId: workspaceId, repoRoot: repoRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("repo-path.txt", isDirectory: false)
    }

    /// Persist a baseline tree SHA for a (workspace, repo) pair to disk. Also
    /// writes the absolute repo path to a sibling file so cold-start recovery
    /// can reconstruct the dict keyed by repo path.
    static func writeBaselineTree(_ tree: String, workspaceId: UUID, repoRoot: String) throws {
        // Touching diffStateDirectory ensures the parent tree exists (it does
        // a mkdir -p the first time). The baseline/repo-path files sit at the
        // sibling level (one level up from `objects/`).
        _ = diffStateDirectory(workspaceId: workspaceId, repoRoot: repoRoot)
        let baselineURL = baselineFileURL(workspaceId: workspaceId, repoRoot: repoRoot)
        let repoPathURL = repoPathFileURL(workspaceId: workspaceId, repoRoot: repoRoot)
        try tree.write(to: baselineURL, atomically: true, encoding: .utf8)
        // Best-effort; baseline alone is enough to make Tier 1 work for the
        // active root, but cold-start enumeration needs to recover the path
        // (the on-disk dir name is just a SHA-256 hash of repoRoot).
        try? repoRoot.write(to: repoPathURL, atomically: true, encoding: .utf8)
    }

    /// Read a previously-persisted baseline tree SHA, or nil if absent/invalid.
    static func readBaselineTree(workspaceId: UUID, repoRoot: String) -> String? {
        let url = baselineFileURL(workspaceId: workspaceId, repoRoot: repoRoot)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40 else { return nil }
        return trimmed
    }

    /// Scan `~/Library/Application Support/cmux/diff-state/<wsId>/` and rebuild
    /// the `[repoPath: baselineTreeSha]` dict from the per-repo `baseline.txt`
    /// + `repo-path.txt` sibling files. Returns an empty dict if the workspace
    /// has no persisted state (e.g., first ever run).
    static func enumerateBaselineTrees(workspaceId: UUID) -> [String: String] {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let workspaceDir = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("diff-state", isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString.lowercased(), isDirectory: true)

        guard let entries = try? fm.contentsOfDirectory(
            at: workspaceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: String] = [:]
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let baselineURL = entry.appendingPathComponent("baseline.txt", isDirectory: false)
            let repoPathURL = entry.appendingPathComponent("repo-path.txt", isDirectory: false)
            guard let baselineRaw = try? String(contentsOf: baselineURL, encoding: .utf8),
                  let repoPathRaw = try? String(contentsOf: repoPathURL, encoding: .utf8) else {
                continue
            }
            let baseline = baselineRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let repoPath = repoPathRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard baseline.count == 40, !repoPath.isEmpty else { continue }
            result[repoPath] = baseline
        }
        return result
    }

    /// Build the env dict that points git at our cmux-owned object store while
    /// keeping the user's `.git/objects/` available for read (HEAD-relative
    /// references resolve through the alternate). `GIT_INDEX_FILE` is left to
    /// callers that need it (write-tree path).
    private static func cmuxObjectEnv(workspaceId: UUID, repoRoot: String) -> [String: String] {
        let store = diffStateDirectory(workspaceId: workspaceId, repoRoot: repoRoot)
        let userObjects = (repoRoot as NSString).appendingPathComponent(".git/objects")
        return [
            "GIT_OBJECT_DIRECTORY": store.path,
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": userObjects
        ]
    }

    // MARK: - Snapshot operations

    /// Stages all current worktree contents (including untracked, respecting .gitignore)
    /// into an isolated index file, then writes the tree object into the cmux
    /// per-(ws, repo) object store. Returns the tree SHA.
    /// The user's real .git/index and .git/objects are never touched.
    @discardableResult
    static func writeTreeIsolated(workspaceId: UUID, in worktree: String) throws -> String {
        let indexPath = NSString.path(withComponents: [
            NSTemporaryDirectory(),
            "cmux-pertd-\(UUID().uuidString).idx"
        ])
        defer { try? FileManager.default.removeItem(atPath: indexPath) }
        var env = cmuxObjectEnv(workspaceId: workspaceId, repoRoot: worktree)
        env["GIT_INDEX_FILE"] = indexPath
        _ = try runGit(in: worktree, arguments: ["add", "-A"], env: env)
        let tree = try runGit(in: worktree, arguments: ["write-tree"], env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.count == 40 else { throw Error.unexpectedOutput("write-tree returned: \(tree)") }
        return tree
    }

    /// Builds a commit object with the given tree, written into the cmux
    /// per-(ws, repo) object store. If `parent` is supplied the commit links to
    /// it via `-p`; otherwise it is parent-less (HEAD-less repo case).
    /// Returns the commit SHA.
    static func commitTree(
        _ tree: String,
        parent: String? = nil,
        message: String,
        workspaceId: UUID,
        in worktree: String
    ) throws -> String {
        var env = cmuxObjectEnv(workspaceId: workspaceId, repoRoot: worktree)
        env["GIT_AUTHOR_NAME"] = "cmux"
        env["GIT_AUTHOR_EMAIL"] = "cmux@local"
        env["GIT_COMMITTER_NAME"] = "cmux"
        env["GIT_COMMITTER_EMAIL"] = "cmux@local"
        var args: [String] = ["commit-tree", tree]
        if let parent, !parent.isEmpty {
            args.append("-p")
            args.append(parent)
        }
        args.append("-m")
        args.append(message)
        let commit = try runGit(
            in: worktree,
            arguments: args,
            env: env
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40 else { throw Error.unexpectedOutput("commit-tree returned: \(commit)") }
        return commit
    }

    /// Best-effort: nuke any legacy `refs/cmux/session-<wsId>/last-turn-base`
    /// that prior versions of cmux wrote into the user's `.git/refs/`. Idempotent
    /// and silent on failure (e.g., ref doesn't exist, repo is read-only).
    /// Does NOT touch the surrounding `refs/cmux/` directory in case other tools
    /// have started using it.
    static func deleteLegacySessionRef(workspaceId: UUID, in worktree: String) {
        let ref = "refs/cmux/session-\(workspaceId.uuidString.lowercased())/last-turn-base"
        _ = try? runGit(in: worktree, arguments: ["update-ref", "-d", ref])
    }

    // MARK: - Diff queries

    /// Which tier `bestEffortDiff` ended up using.
    enum DiffTier {
        case sessionBaseline  // Tier 1: in-memory baseline tree SHA from manager
        case head             // Tier 2: HEAD
        case syntheticAdded   // Tier 3: synthetic everything-as-added (no commits yet)
        case empty            // Nothing to show
    }

    /// Get the active diff for the working tree using the best available baseline.
    /// Tier 1: against the manager's in-memory baseline tree SHA (if non-nil)
    /// Tier 2: against HEAD (if HEAD exists)
    /// Tier 3: full working-tree diff treating everything as added
    /// Returns the unified-diff string and the tier used. Empty string if nothing to show.
    ///
    /// `baselineTreeSha` lives in the cmux per-(ws, repo) object store; HEAD
    /// lives in the user's `.git/objects/`. Both diff invocations set
    /// `GIT_OBJECT_DIRECTORY` + `GIT_ALTERNATE_OBJECT_DIRECTORIES` so the
    /// resolver can see both stores.
    static func bestEffortDiff(
        workspaceId: UUID,
        baselineTreeSha: String?,
        in worktree: String
    ) -> (diff: String, tier: DiffTier) {
        let trimmedRoot = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty,
              FileManager.default.fileExists(atPath: trimmedRoot) else {
            return ("", .empty)
        }

        // Tier 1: in-memory baseline tree → fresh tree, both in cmux store.
        if let baselineTreeSha, !baselineTreeSha.isEmpty {
            do {
                let freshTree = try writeTreeIsolated(workspaceId: workspaceId, in: trimmedRoot)
                let env = cmuxObjectEnv(workspaceId: workspaceId, repoRoot: trimmedRoot)
                let diff = try runGit(
                    in: trimmedRoot,
                    arguments: [
                        "diff",
                        "--no-color",
                        "--no-ext-diff",
                        "--unified=3",
                        baselineTreeSha,
                        freshTree
                    ],
                    env: env,
                    allowExitOne: true
                )
                #if DEBUG
                cmuxDebugLog(
                    "turn-diff: tier1 diff-tree base=\(baselineTreeSha.prefix(7)) now=\(freshTree.prefix(7)) bytes=\(diff.utf8.count)"
                )
                #endif
                return (diff, .sessionBaseline)
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: bestEffortDiff failed in \(trimmedRoot): tier1 baseline-diff error \(error)")
                #endif
            }
        }

        // Tier 2: HEAD. Same tree-vs-tree approach as tier 1 — `git diff HEAD`
        // would compare HEAD against the index (empty for cmux users), missing
        // every untracked file and falsely reporting tracked files as deleted.
        // HEAD lives in the user's .git/objects (resolved via alternate),
        // freshTree lives in the cmux store.
        if refExists("HEAD", in: trimmedRoot) {
            do {
                let freshTree = try writeTreeIsolated(workspaceId: workspaceId, in: trimmedRoot)
                let env = cmuxObjectEnv(workspaceId: workspaceId, repoRoot: trimmedRoot)
                let diff = try runGit(
                    in: trimmedRoot,
                    arguments: [
                        "diff",
                        "--no-color",
                        "--no-ext-diff",
                        "--unified=3",
                        "HEAD^{tree}",
                        freshTree
                    ],
                    env: env,
                    allowExitOne: true
                )
                #if DEBUG
                let baseTree = (try? runGit(
                    in: trimmedRoot,
                    arguments: ["rev-parse", "HEAD^{tree}"]
                ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                cmuxDebugLog(
                    "turn-diff: tier2 diff-tree base=HEAD^{tree}=\(baseTree.prefix(7)) now=\(freshTree.prefix(7)) bytes=\(diff.utf8.count)"
                )
                #endif
                return (diff, .head)
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: bestEffortDiff failed in \(trimmedRoot): tier2 HEAD-diff error \(error)")
                #endif
            }
        }

        // Tier 3: synthetic everything-as-added. Brand-new repo with no HEAD.
        let synth = syntheticAddedDiff(in: trimmedRoot, untrackedOnly: false)
        if synth.isEmpty {
            return ("", .empty)
        }
        return (synth, .syntheticAdded)
    }

    // MARK: - Tier helpers

    /// True iff `git rev-parse --verify <ref>` succeeds. Used to gate diff calls
    /// against HEAD that may not exist (fresh repo / detached / missing).
    static func refExists(_ ref: String, in worktree: String) -> Bool {
        do {
            _ = try runGit(in: worktree, arguments: ["rev-parse", "--verify", "--quiet", ref])
            return true
        } catch {
            return false
        }
    }

    /// Build a synthetic unified diff that emits every file under the worktree
    /// as an addition. Used when there is no baseline (fresh repo, no commits).
    /// If `untrackedOnly` is true, only files git reports as `??` (untracked) are
    /// included — used to augment `git diff HEAD` with untracked additions.
    /// Skips files git considers binary.
    static func syntheticAddedDiff(in worktree: String, untrackedOnly: Bool) -> String {
        let porcelain: String
        do {
            porcelain = try runGit(
                in: worktree,
                arguments: ["status", "--porcelain", "--untracked-files=all"]
            )
        } catch {
            #if DEBUG
            cmuxDebugLog("turn-diff: bestEffortDiff failed in \(worktree): status porcelain error \(error)")
            #endif
            return ""
        }

        var pieces: [String] = []
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Porcelain v1: "XY path" with X/Y in cols 0/1, space at 2, path from col 3.
            // For untracked it's "?? path".
            guard line.count > 3 else { continue }
            let xy = String(line.prefix(2))
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var path = String(line[pathStart...])
            // Renames look like "old -> new" — keep just the new side.
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            // Strip optional surrounding quotes git uses for paths with funky chars.
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            let isUntracked = (xy == "??")
            if untrackedOnly && !isUntracked { continue }
            // Deletions (" D" / "D ") have no working-tree file to read.
            if xy.contains("D") { continue }

            // Use git diff --no-index against /dev/null: produces a real unified
            // diff that respects git's own binary detection (skipped via grep below).
            let diff: String
            do {
                diff = try runGit(
                    in: worktree,
                    arguments: [
                        "diff",
                        "--no-color",
                        "--no-ext-diff",
                        "--unified=3",
                        "--no-index",
                        "--",
                        "/dev/null",
                        path
                    ],
                    allowExitOne: true
                )
            } catch {
                continue
            }
            // Skip git's "Binary files ... differ" sentinel — diff2html chokes on it
            // and there's nothing useful to show anyway.
            if diff.contains("Binary files ") && !diff.contains("@@") { continue }
            if diff.isEmpty { continue }
            pieces.append(diff)
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - runGit

    @discardableResult
    private static func runGit(
        in directory: String,
        arguments: [String],
        env: [String: String] = [:],
        allowExitOne: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        if !env.isEmpty {
            var combined = ProcessInfo.processInfo.environment
            for (k, v) in env { combined[k] = v }
            process.environment = combined
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        // git diff --no-index returns 1 when files differ — that's success for us.
        let isAcceptable = status == 0 || (allowExitOne && status == 1)
        if !isAcceptable {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw Error.gitFailed(stderr: err, exitCode: status)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

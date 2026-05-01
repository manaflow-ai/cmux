import Foundation

/// Stateless wrapper for git plumbing operations used by the per-turn diff snapshotting.
/// Uses /usr/bin/git shell-out (matches existing pattern in Sources/FileExplorerStore.swift:958).
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

    // MARK: - Snapshot operations

    /// Stages all current worktree contents (including untracked, respecting .gitignore)
    /// into an isolated index file, then writes the tree object. Returns the tree SHA.
    /// The user's real .git/index is never touched.
    @discardableResult
    static func writeTreeIsolated(in worktree: String) throws -> String {
        let indexPath = NSString.path(withComponents: [
            NSTemporaryDirectory(),
            "cmux-pertd-\(UUID().uuidString).idx"
        ])
        defer { try? FileManager.default.removeItem(atPath: indexPath) }
        let env = ["GIT_INDEX_FILE": indexPath]
        _ = try runGit(in: worktree, arguments: ["add", "-A"], env: env)
        let tree = try runGit(in: worktree, arguments: ["write-tree"], env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree.count == 40 else { throw Error.unexpectedOutput("write-tree returned: \(tree)") }
        return tree
    }

    /// Builds a commit object with the given tree and parent. Returns the commit SHA.
    static func commitTree(_ tree: String, parent: String, message: String, in worktree: String) throws -> String {
        let env: [String: String] = [
            "GIT_AUTHOR_NAME": "cmux", "GIT_AUTHOR_EMAIL": "cmux@local",
            "GIT_COMMITTER_NAME": "cmux", "GIT_COMMITTER_EMAIL": "cmux@local"
        ]
        let commit = try runGit(
            in: worktree,
            arguments: ["commit-tree", tree, "-p", parent, "-m", message],
            env: env
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.count == 40 else { throw Error.unexpectedOutput("commit-tree returned: \(commit)") }
        return commit
    }

    static func refName(for session: UUID) -> String {
        "refs/cmux/session-\(session.uuidString.lowercased())/last-turn-base"
    }

    static func updateRef(session: UUID, commit: String, in worktree: String) throws {
        _ = try runGit(in: worktree, arguments: ["update-ref", refName(for: session), commit])
    }

    static func cleanup(session: UUID, in worktree: String) throws {
        _ = try runGit(in: worktree, arguments: ["update-ref", "-d", refName(for: session)])
    }

    // MARK: - Diff queries

    /// Diff between session's last-turn-base ref and the working tree.
    /// Returns unified diff text suitable for diff2html.
    static func diffAgainstWorkingTree(session: UUID, in worktree: String) throws -> String {
        try runGit(
            in: worktree,
            arguments: [
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--unified=3",
                refName(for: session)
            ]
        )
    }

    /// Which tier `bestEffortDiff` ended up using.
    enum DiffTier {
        case sessionRef       // Tier 1: refs/cmux/session-<uuid>/last-turn-base
        case head             // Tier 2: HEAD
        case syntheticAdded   // Tier 3: synthetic everything-as-added (no commits yet)
        case empty            // Nothing to show
    }

    /// Get the active diff for the working tree using the best available baseline.
    /// Tier 1: against the session's last-turn-base ref (if it exists)
    /// Tier 2: against HEAD (if HEAD exists)
    /// Tier 3: full working-tree diff treating everything as added
    /// Returns the unified-diff string and the tier used. Empty string if nothing to show.
    static func bestEffortDiff(session: UUID, in worktree: String) -> (diff: String, tier: DiffTier) {
        let trimmedRoot = worktree.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty,
              FileManager.default.fileExists(atPath: trimmedRoot) else {
            return ("", .empty)
        }

        // Tier 1: session ref
        if refExists(refName(for: session), in: trimmedRoot) {
            do {
                let diff = try diffAgainstWorkingTree(session: session, in: trimmedRoot)
                return (diff, .sessionRef)
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: bestEffortDiff failed in \(trimmedRoot): tier1 ref-diff error \(error)")
                #endif
            }
        }

        // Tier 2: HEAD
        if refExists("HEAD", in: trimmedRoot) {
            do {
                let diff = try runGit(
                    in: trimmedRoot,
                    arguments: [
                        "diff",
                        "--no-color",
                        "--no-ext-diff",
                        "--unified=3",
                        "HEAD"
                    ]
                )
                // `git diff HEAD` shows tracked-file changes only. Append untracked
                // files as additions so the panel matches what the user sees.
                let untracked = syntheticAddedDiff(in: trimmedRoot, untrackedOnly: true)
                let combined: String
                if diff.isEmpty {
                    combined = untracked
                } else if untracked.isEmpty {
                    combined = diff
                } else {
                    combined = diff + (diff.hasSuffix("\n") ? "" : "\n") + untracked
                }
                return (combined, .head)
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
    /// against refs/HEAD that may not exist (fresh repo / detached / missing).
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

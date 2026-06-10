import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import Darwin
import Foundation
import os
import SQLite3


// MARK: - Claude session scanning
extension SessionIndexStore {
    private struct ClaudeParsed {
        var title: String = ""
        var cwd: String?
        var branch: String?
        var pr: PullRequestLink?
        var model: String?
        var permissionMode: String?
    }

    private struct ClaudeSessionRoot: Hashable {
        let configDir: String
        let resumeConfigDirectory: String?

        var projectsRoot: String {
            (configDir as NSString).appendingPathComponent("projects")
        }
    }

    private struct ClaudeSessionCandidate: Sendable {
        let url: URL
        let mtime: Date
        let dirName: String
        let resumeConfigDirectory: String?
        let prefilteredByRipgrep: Bool
    }

    nonisolated private static func claudeSessionRoots() -> [ClaudeSessionRoot] {
        let fm = FileManager.default
        var roots: [ClaudeSessionRoot] = []
        var seen: Set<String> = []

        func appendRoot(_ rawPath: String?, requireConfigured: Bool) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let configDir = (trimmed as NSString).expandingTildeInPath
            let standardized = ClaudeConfigDirectoryPath.preferredPath(configDir)
            let projectsRoot = (standardized as NSString).appendingPathComponent("projects")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectsRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }
            let resumeConfigDirectory = ClaudeConfigurationRoot.configuredResumeDirectory(
                standardized,
                fileManager: fm
            )
            if requireConfigured, resumeConfigDirectory == nil {
                return
            }
            guard seen.insert(standardized).inserted else { return }
            roots.append(
                ClaudeSessionRoot(
                    configDir: standardized,
                    resumeConfigDirectory: resumeConfigDirectory
                )
            )
        }

        let environmentConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        appendRoot(environmentConfigDir, requireConfigured: false)

        let accountRoot = ("~/.codex-accounts/claude" as NSString).expandingTildeInPath
        if let accountDirs = try? fm.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                appendRoot(
                    (accountRoot as NSString).appendingPathComponent(accountDir),
                    requireConfigured: true
                )
            }
        }

        appendRoot(
            ("~/.claude" as NSString).expandingTildeInPath,
            requireConfigured: false
        )

        return roots
    }

    nonisolated private static func extractClaudeMetadata(head: String, tail: String, projectDir: String) -> ClaudeParsed {
        var out = ClaudeParsed()
        out.cwd = decodeClaudeProjectDir(projectDir)

        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let isMeta = (obj["isMeta"] as? Bool) ?? false
            if let cwdField = obj["cwd"] as? String, !cwdField.isEmpty {
                out.cwd = cwdField
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
            if out.title.isEmpty,
               (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "user" {
                if let content = message["content"] as? String,
                   let title = SessionEntry.claudeDisplayTitle(from: content, isMeta: isMeta) {
                    out.title = title
                } else if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if (part["type"] as? String) == "text",
                           let text = part["text"] as? String,
                           let title = SessionEntry.claudeDisplayTitle(from: text, isMeta: isMeta) {
                            out.title = title
                            break
                        }
                    }
                }
            }
        }

        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "pr-link", let number = obj["prNumber"] as? Int,
               let url = obj["prUrl"] as? String {
                out.pr = PullRequestLink(
                    number: number,
                    url: url,
                    repository: obj["prRepository"] as? String
                )
            }
            if let branchField = obj["gitBranch"] as? String, !branchField.isEmpty {
                out.branch = branchField
            }
            if let mode = obj["permissionMode"] as? String, !mode.isEmpty {
                out.permissionMode = mode
            }
            if (obj["type"] as? String) == "assistant",
               let message = obj["message"] as? [String: Any],
               let model = message["model"] as? String, !model.isEmpty {
                out.model = model
            }
        }
        // Strip the [1m] suffix some Claude internal model IDs carry (claude-opus-4-7[1m]).
        if let m = out.model, let bracket = m.firstIndex(of: "[") {
            out.model = String(m[..<bracket])
        }
        return out
    }

    nonisolated private static func decodeClaudeProjectDir(_ raw: String) -> String? {
        // Claude encodes cwd by replacing "/" with "-" and prefixing "-"
        // e.g. "-Users-lawrence-fun-cmuxterm-hq" -> "/Users/lawrence/fun/cmuxterm-hq".
        // The encoding is lossy: a real path segment containing "-"
        // (e.g. "my-cool-project") collapses to multiple segments
        // ("/my/cool/project") on decode, which is wrong. Only return the
        // candidate if it actually exists on disk; otherwise let the caller
        // fall back to the JSONL `cwd` field.
        guard !raw.isEmpty else { return nil }
        let stripped = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        let candidate = "/" + stripped.replacingOccurrences(of: "-", with: "/")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return candidate
    }

    nonisolated private static func claudeProjectDirName(for url: URL, projectsRoot: String) -> String {
        let root = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
        guard url.path.hasPrefix(root) else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        let relative = String(url.path.dropFirst(root.count))
        return relative.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? url.deletingLastPathComponent().lastPathComponent
    }

    nonisolated private static func enumerateClaudeJSONLCandidates(
        root: ClaudeSessionRoot,
        cwdFilter: String?,
        prefilteredByRipgrep: Bool
    ) -> [ClaudeSessionCandidate] {
        let fm = FileManager.default
        var candidates: [ClaudeSessionCandidate] = []

        func appendJSONLFiles(in dirPath: String, dirName: String) {
            guard let contents = try? fm.contentsOfDirectory(atPath: dirPath) else { return }
            for name in contents where name.hasSuffix(".jsonl") {
                let filePath = (dirPath as NSString).appendingPathComponent(name)
                let url = URL(fileURLWithPath: filePath)
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                candidates.append(
                    ClaudeSessionCandidate(
                        url: url,
                        mtime: mtime,
                        dirName: dirName,
                        resumeConfigDirectory: root.resumeConfigDirectory,
                        prefilteredByRipgrep: prefilteredByRipgrep
                    )
                )
            }
        }

        if let cwdFilter {
            // Single-sourced with RestorableAgentSessionIndex so this fast-path cwd filter
            // encodes dotted paths ("." -> "-") identically to the transcript-discovery path.
            let dirName = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwdFilter)
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                appendJSONLFiles(in: dirPath, dirName: dirName)
            }
            return candidates
        }

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: root.projectsRoot) else {
            return candidates
        }
        for dirName in projectDirs {
            let dirPath = (root.projectsRoot as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            appendJSONLFiles(in: dirPath, dirName: dirName)
        }
        return candidates
    }

    // MARK: Codex

    /// Returns Claude session entries paginated by mtime desc.
    /// - When `needle` is empty: fast path. Skips rg, enumerates configured Claude
    ///   roots, takes the top `offset+limit` by mtime, parses metadata, returns the slice.
    /// - When `needle` is non-empty and rg is on PATH: rg pre-filters the candidate
    ///   set; we only parse files that actually contain the needle.
    /// - When `needle` is non-empty and rg is missing/failed: falls back to the
    ///   Foundation enumeration + 64 KB head + 32 KB tail substring scan.
    nonisolated static func loadClaudeEntries(
        needle: String, cwdFilter: String?, offset: Int, limit: Int
    ) async -> [SessionEntry] {
        let roots = claudeSessionRoots()
        guard !roots.isEmpty else { return [] }
        let fm = FileManager.default

        // Pre-filter via rg when we have a needle — rg is parallel, mmaps the
        // file, and scans the WHOLE file (not just our 128 KB head), so it both
        // speeds the scan up and finds matches deeper in long transcripts.
        var candidates: [ClaudeSessionCandidate] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepMatchingPaths(
                    needle: needle,
                    root: root.projectsRoot,
                    fileGlob: "*.jsonl"
                ) else {
                    candidates.append(
                        contentsOf: enumerateClaudeJSONLCandidates(
                            root: root,
                            cwdFilter: cwdFilter,
                            prefilteredByRipgrep: false
                        )
                    )
                    continue
                }
                for url in rgPaths {
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    let dirName = claudeProjectDirName(for: url, projectsRoot: root.projectsRoot)
                    candidates.append(
                        ClaudeSessionCandidate(
                            url: url,
                            mtime: mtime,
                            dirName: dirName,
                            resumeConfigDirectory: root.resumeConfigDirectory,
                            prefilteredByRipgrep: true
                        )
                    )
                }
            }
        } else if let cwdFilter {
            // Fast path: the project directory name encodes the cwd. We can skip
            // enumerating every other project entirely.
            for root in roots {
                candidates.append(
                    contentsOf: enumerateClaudeJSONLCandidates(
                        root: root,
                        cwdFilter: cwdFilter,
                        prefilteredByRipgrep: false
                    )
                )
            }
        } else {
            for root in roots {
                candidates.append(
                    contentsOf: enumerateClaudeJSONLCandidates(
                        root: root,
                        cwdFilter: nil,
                        prefilteredByRipgrep: false
                    )
                )
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // Take a generous window of candidates to inspect in parallel. We need
        // enough to cover both targets and skipped files; we'll trim to
        // (offset+limit) matches afterwards. Cap at searchMaxFiles.
        let target = offset + limit
        let workSize = min(target * 2, candidates.count, searchMaxFiles)
        let workCandidates = Array(candidates.prefix(workSize))

        #if DEBUG
        let loopStart = ProcessInfo.processInfo.systemUptime
        #endif

        // Parallelize per-file work. Each file's read + parse is independent;
        // running them in a TaskGroup lets the cooperative pool fan I/O out
        // across cores instead of one-file-at-a-time blocking on disk.
        let processed: [(Int, SessionEntry?, Bool)] = await withTaskGroup(
            of: (Int, SessionEntry?, Bool).self
        ) { group in
            for (idx, candidate) in workCandidates.enumerated() {
                group.addTask {
                    // Cache hit
                    let cached = ClaudeMetadataCache.shared.get(url: candidate.url, mtime: candidate.mtime)
                    if let cached, needle.isEmpty || candidate.prefilteredByRipgrep {
                        if let cwdFilter, cached.cwd != cwdFilter { return (idx, nil, true) }
                        return (
                            idx,
                            cached.withClaudeConfigDirectoryForResume(candidate.resumeConfigDirectory),
                            true
                        )
                    }
                    let head = readFileHead(url: candidate.url, byteCap: headByteCap)
                    let tail = readFileTail(url: candidate.url, byteCap: tailByteCap)
                    if !needle.isEmpty && !candidate.prefilteredByRipgrep {
                        let combined = head + "\n" + tail
                        if combined.range(of: needle, options: [.caseInsensitive, .literal]) == nil {
                            return (idx, nil, false)
                        }
                    }
                    if let cached {
                        if let cwdFilter, cached.cwd != cwdFilter { return (idx, nil, true) }
                        return (
                            idx,
                            cached.withClaudeConfigDirectoryForResume(candidate.resumeConfigDirectory),
                            true
                        )
                    }
                    let parsed = extractClaudeMetadata(head: head, tail: tail, projectDir: candidate.dirName)
                    if let cwdFilter, parsed.cwd != cwdFilter { return (idx, nil, false) }
                    let sid = candidate.url.deletingPathExtension().lastPathComponent
                    let entry = SessionEntry(
                        id: "claude:" + candidate.url.path,
                        agent: .claude,
                        sessionId: sid,
                        title: parsed.title,
                        cwd: parsed.cwd,
                        gitBranch: parsed.branch,
                        pullRequest: parsed.pr,
                        modified: candidate.mtime,
                        fileURL: candidate.url,
                        specifics: .claude(
                            model: parsed.model,
                            permissionMode: parsed.permissionMode,
                            configDirectoryForResume: candidate.resumeConfigDirectory
                        )
                    )
                    if needle.isEmpty {
                        ClaudeMetadataCache.shared.put(
                            url: candidate.url,
                            mtime: candidate.mtime,
                            entry: entry
                        )
                    }
                    return (idx, entry, false)
                }
            }
            var collected: [(Int, SessionEntry?, Bool)] = []
            collected.reserveCapacity(workCandidates.count)
            for await item in group { collected.append(item) }
            return collected
        }
        // Restore original mtime ordering (TaskGroup completes out-of-order).
        let sorted = processed.sorted { $0.0 < $1.0 }
        let matched = sorted.compactMap { $0.1 }
        #if DEBUG
        let cachedCount = sorted.filter { $0.2 }.count
        let skippedCount = sorted.filter { $0.1 == nil && !$0.2 }.count + sorted.filter { $0.1 == nil && $0.2 }.count
        let totalMs = (ProcessInfo.processInfo.systemUptime - loopStart) * 1000
        cmuxDebugLog("session.claude.detail target=\(target) workSize=\(workSize) matched=\(matched.count) cachedHits=\(cachedCount) skipped=\(skippedCount) parallelMs=\(Int(totalMs))")
        #endif
        return Array(matched.prefix(target).dropFirst(offset).prefix(limit))
    }

}

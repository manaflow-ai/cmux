import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Workspace Group Resolution
extension CmuxConfigStore {
    /// Public lookup: given an anchor workspace's cwd, return the best-matching
    /// resolved group config. Matching uses auto-glob detection (keys with `*`
    /// or `?` are treated as fnmatch globs, others as path prefixes). Longest
    /// matching key wins. Returns nil when nothing matches.
    func resolveWorkspaceGroupConfig(forCwd cwd: String?) -> CmuxResolvedWorkspaceGroupConfig? {
        guard let cwd, !cwd.isEmpty, !workspaceGroupConfigs.isEmpty else { return nil }
        let normalizedCwd = Self.normalizeAbsolutePath(cwd)
        var best: (CmuxResolvedWorkspaceGroupConfig, Int)?
        for entry in workspaceGroupConfigs {
            guard Self.cwdEntryMatches(entry, cwd: normalizedCwd) else { continue }
            let score = entry.normalizedKey.count
            if best == nil || score > best!.1 {
                best = (entry, score)
            }
        }
        return best?.0
    }

    /// Replace a leading `~` with the user's home directory while preserving
    /// the rest of the pattern (including `*`/`?` glob characters). Unlike
    /// `normalizeAbsolutePath`, this skips `standardizingPath` so trailing
    /// glob segments aren't collapsed.
    private static func expandTildePreservingGlob(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = trimmed.dropFirst()
        return suffix.isEmpty ? home : home + String(suffix)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let suffix = trimmed.dropFirst()
            return suffix.isEmpty ? home : home + String(suffix)
        }
        return (trimmed as NSString).standardizingPath
    }

    private static func cwdEntryMatches(
        _ entry: CmuxResolvedWorkspaceGroupConfig,
        cwd: String
    ) -> Bool {
        let key = entry.normalizedKey
        if entry.isGlob {
            return fnmatchStyle(pattern: key, candidate: cwd)
        }
        if cwd == key { return true }
        // Root prefix `/` is a documented catch-all; without this branch
        // any non-root cwd would be tested against "//" and fail. Other
        // keys append `/` so `/Users/lawrence` doesn't also match
        // `/Users/lawrence-fork`.
        if key == "/" {
            return cwd.hasPrefix("/")
        }
        return cwd.hasPrefix(key + "/")
    }

    /// Minimal fnmatch: `*` matches any run of characters within a path segment
    /// (and across path separators); `?` matches a single character. Sufficient
    /// for the byCwd matching contract — full fnmatch features can come later.
    private static func fnmatchStyle(pattern: String, candidate: String) -> Bool {
        let p = Array(pattern)
        let s = Array(candidate)
        var pi = 0
        var si = 0
        var starP = -1
        var starS = -1
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi
                starS = si
                pi += 1
            } else if starP != -1 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    func resolveWorkspaceGroupConfigsFromLayers(
        localConfig: CmuxConfigFile?,
        globalConfig: CmuxConfigFile?,
        localPath: String?,
        globalPath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> [CmuxResolvedWorkspaceGroupConfig] {
        var resolved: [String: CmuxResolvedWorkspaceGroupConfig] = [:]
        if let globalEntries = globalConfig?.workspaceGroups?.byCwd {
            for (key, entry) in globalEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r
                }
            }
        }
        if let localEntries = localConfig?.workspaceGroups?.byCwd {
            for (key, entry) in localEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: localPath ?? globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r // local overrides global
                }
            }
        }
        return Array(resolved.values).sorted { $0.normalizedKey.count > $1.normalizedKey.count }
    }

    private func resolveWorkspaceGroupConfigEntry(
        key: String,
        entry: CmuxConfigWorkspaceGroupEntry,
        sourcePath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> CmuxResolvedWorkspaceGroupConfig? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isGlob = trimmed.contains("*") || trimmed.contains("?")
        // Expand `~` in both glob and prefix keys so a key like
        // `~/projects/*` matches workspace cwds that are already normalized to
        // absolute paths (`/Users/<you>/projects/foo`). Prefix keys also go
        // through `standardizingPath` so trailing `/.` and similar are
        // canonicalized.
        let normalizedKey = isGlob
            ? Self.expandTildePreservingGlob(trimmed)
            : Self.normalizeAbsolutePath(trimmed)
        let menuResolution = resolvedConfigContextMenuItems(
            entry.contextMenu,
            actions: actions,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "workspaceGroups.byCwd[\(key)].contextMenu",
            settingSourcePath: sourcePath
        )
        issues.append(contentsOf: menuResolution.issues)
        return CmuxResolvedWorkspaceGroupConfig(
            originalKey: trimmed,
            normalizedKey: normalizedKey,
            isGlob: isGlob,
            color: entry.color.map(sanitizeConfigText),
            iconSymbol: entry.icon.map(sanitizeConfigText),
            contextMenuItems: menuResolution.items,
            newWorkspacePlacement: WorkspaceGroupNewPlacement(rawString: entry.newWorkspacePlacement)
        )
    }

}

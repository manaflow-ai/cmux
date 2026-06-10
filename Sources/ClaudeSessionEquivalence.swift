import Foundation

/// Pure, deterministic remote↔local path equivalence used to make the Claude
/// "this folder only" session filter work across a mount boundary.
///
/// A reporter setup: Claude Code runs in a Docker dev container whose
/// `/workspace` is a mount of the Mac's `/Users/<me>`. Transcripts written with
/// a container cwd like `/workspace/p/x` are visible on the Mac but never match
/// their local twin `/Users/<me>/p/x`. Configuring a mapping
/// `{ "remote": "/workspace", "local": "/Users/<me>" }` makes both the slug
/// fast-path lookup and the per-entry cwd comparison treat the two as the same
/// folder.
///
/// Matching is intentionally a single prefix substitution per mapping, applied
/// in both directions. No filesystem access — fully unit-testable.
struct ClaudePathEquivalence: Hashable, Sendable {
    /// A normalized pair of equivalent path prefixes (no trailing slash, tilde
    /// expanded, never empty and never the filesystem root).
    struct NormalizedMapping: Hashable, Sendable {
        let remote: String
        let local: String
    }

    let mappings: [NormalizedMapping]

    init(mappings rawMappings: [CmuxVaultPathMapping], homeDirectory: String = NSHomeDirectory()) {
        var seen = Set<NormalizedMapping>()
        var normalized: [NormalizedMapping] = []
        for raw in rawMappings {
            guard let remote = Self.normalizePrefix(raw.remote, homeDirectory: homeDirectory),
                  let local = Self.normalizePrefix(raw.local, homeDirectory: homeDirectory),
                  remote != local else {
                continue
            }
            let mapping = NormalizedMapping(remote: remote, local: local)
            if seen.insert(mapping).inserted {
                normalized.append(mapping)
            }
        }
        self.mappings = normalized
    }

    var isEmpty: Bool { mappings.isEmpty }

    /// Expands a leading tilde, trims whitespace, and strips trailing slashes.
    /// Returns nil for empty input or for a bare root (`/`, `~`), which would
    /// otherwise match every path.
    static func normalizePrefix(_ raw: String, homeDirectory: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
            path = home + String(path.dropFirst(1))
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty, path != "/" else { return nil }
        return path
    }

    /// Returns every path considered equivalent to `path`, including `path`
    /// itself. O(mappings).
    func variants(of path: String) -> [String] {
        guard !mappings.isEmpty else { return [path] }
        var result = [path]
        var seen: Set<String> = [path]
        for mapping in mappings {
            for (from, to) in [(mapping.remote, mapping.local), (mapping.local, mapping.remote)] {
                guard let mapped = Self.substitutePrefix(path, from: from, to: to) else { continue }
                if seen.insert(mapped).inserted {
                    result.append(mapped)
                }
            }
        }
        return result
    }

    /// True when `a` and `b` are equal or related by a configured mapping.
    func equates(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !mappings.isEmpty else { return false }
        let aVariants = Set(variants(of: a))
        if aVariants.contains(b) { return true }
        return !aVariants.isDisjoint(with: Set(variants(of: b)))
    }

    /// Candidate Claude project-directory slugs for a workspace folder: the
    /// literal slug plus one per mapped variant of the folder. Deduped, literal
    /// first. O(mappings).
    func projectDirSlugCandidates(forCwd cwd: String) -> [String] {
        var seen = Set<String>()
        var slugs: [String] = []
        for variant in variants(of: cwd) {
            let slug = RestorableAgentSessionIndex.encodeClaudeProjectDir(variant)
            if seen.insert(slug).inserted {
                slugs.append(slug)
            }
        }
        return slugs
    }

    /// Substitutes a leading `from` prefix with `to`. Only matches whole path
    /// segments (`from` itself or `from` followed by `/`), so `/work` does not
    /// match `/workspace`.
    private static func substitutePrefix(_ path: String, from: String, to: String) -> String? {
        if path == from { return to }
        let boundary = from + "/"
        guard path.hasPrefix(boundary) else { return nil }
        return to + path.dropFirst(from.count)
    }
}

extension ClaudePathEquivalence {
    /// Extra Claude config roots plus the path-equivalence table configured in
    /// the user's `~/.config/cmux/cmux.json` Vault section. Returns empty
    /// values when the file is missing or unparseable.
    nonisolated static func loadVaultClaudeConfig(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> (extraRoots: [String], equivalence: ClaudePathEquivalence) {
        let configPath = (homeDirectory as NSString)
            .appendingPathComponent(".config/cmux/cmux.json")
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              !data.isEmpty,
              let sanitized = try? JSONCParser.preprocess(data: data),
              let config = try? JSONDecoder().decode(CmuxConfigFile.self, from: sanitized),
              let vault = config.vault else {
            return ([], ClaudePathEquivalence(mappings: [], homeDirectory: homeDirectory))
        }
        return (
            vault.claudeSessionRoots,
            ClaudePathEquivalence(mappings: vault.claudePathMappings, homeDirectory: homeDirectory)
        )
    }
}

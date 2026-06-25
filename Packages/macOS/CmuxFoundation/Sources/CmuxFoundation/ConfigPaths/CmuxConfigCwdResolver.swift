import Foundation

/// Pure path math for resolving and normalizing workspace working directories
/// declared in cmux configuration. Every transform here touches only
/// `FileManager.homeDirectoryForCurrentUser` plus `String`/`Array`, so the type
/// is a small `Sendable` value carrying the `FileManager` it resolves the home
/// directory against (inject a scoped one in tests).
public struct CmuxConfigCwdResolver: Sendable {
    private let homeDirectoryPath: String

    /// Build a resolver that reads the home directory from `fileManager`.
    public init(fileManager: FileManager = .default) {
        self.homeDirectoryPath = fileManager.homeDirectoryForCurrentUser.path
    }

    /// Resolve a configured `cwd` against `baseCwd`. `nil`, empty, and `"."`
    /// fall back to `baseCwd`; a leading `~`/`~/` expands to the home directory;
    /// an absolute path is returned as-is; anything else is appended to
    /// `baseCwd`.
    public func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            if cwd == "~" { return homeDirectoryPath }
            return (homeDirectoryPath as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }

    /// Replace a leading `~` with the user's home directory while preserving
    /// the rest of the pattern (including `*`/`?` glob characters). Unlike
    /// ``normalizeAbsolutePath(_:)``, this skips `standardizingPath` so trailing
    /// glob segments aren't collapsed.
    public func expandTildePreservingGlob(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        let suffix = trimmed.dropFirst()
        return suffix.isEmpty ? homeDirectoryPath : homeDirectoryPath + String(suffix)
    }

    /// Normalize a configured path to an absolute, standardized form, expanding
    /// a leading `~`/`~/` and otherwise running `standardizingPath`.
    public func normalizeAbsolutePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("~") {
            let suffix = trimmed.dropFirst()
            return suffix.isEmpty ? homeDirectoryPath : homeDirectoryPath + String(suffix)
        }
        return (trimmed as NSString).standardizingPath
    }

    /// Minimal fnmatch: `*` matches any run of characters within a path segment
    /// (and across path separators); `?` matches a single character. Sufficient
    /// for the byCwd matching contract — full fnmatch features can come later.
    /// This is pure on its inputs and stateless, so it is a `static` member.
    public static func fnmatchStyle(pattern: String, candidate: String) -> Bool {
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
}

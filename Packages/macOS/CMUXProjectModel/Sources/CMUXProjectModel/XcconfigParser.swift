import Foundation

/// A minimal `.xcconfig` parser that flattens key/value assignments,
/// following `#include` / `#include?` directives and stripping line
/// comments.
///
/// This is intentionally small and lossy: conditional keys
/// (`OTHER_LDFLAGS[sdk=iphoneos*]`) are stored under their literal
/// dotted name, `$(inherited)` is preserved verbatim, and no variable
/// substitution is performed. The goal is just to surface the static
/// values the Targets pane and Build Settings Levels view need for
/// `PRODUCT_BUNDLE_IDENTIFIER`, `*_DEPLOYMENT_TARGET`,
/// `SUPPORTED_PLATFORMS`, and friends.
public enum XcconfigParser {
    /// Parse the file at ``url`` and merge it, plus every transitive
    /// include, into a single `[key: value]` dictionary.
    ///
    /// Later assignments override earlier ones; `#include`d files are
    /// merged before the including file's own assignments so the
    /// including file wins on conflicts.
    public static func parse(at url: URL) throws -> [String: String] {
        var visited: Set<URL> = []
        return try parseRecursive(at: url, visited: &visited)
    }

    /// Convenience: merge a stack of xcconfig URLs into one map. The last
    /// URL in the array wins on conflicts.
    public static func parseChain(_ urls: [URL]) -> [String: String] {
        var merged: [String: String] = [:]
        for url in urls {
            guard let resolved = try? parse(at: url) else { continue }
            for (key, value) in resolved {
                merged[key] = value
            }
        }
        return merged
    }

    private static func parseRecursive(at url: URL, visited: inout Set<URL>) throws -> [String: String] {
        let canonical = url.standardizedFileURL
        if visited.contains(canonical) { return [:] }
        visited.insert(canonical)
        let raw = try String(contentsOf: canonical, encoding: .utf8)
        var out: [String: String] = [:]
        let directory = canonical.deletingLastPathComponent()
        for rawLine in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let include = parseInclude(line, relativeTo: directory) {
                let nested = (try? parseRecursive(at: include.url, visited: &visited)) ?? [:]
                if !include.optional && (try? Data(contentsOf: include.url)) == nil {
                    continue
                }
                for (k, v) in nested { out[k] = v }
                continue
            }
            if let (key, value) = parseAssignment(line) {
                out[key] = value
            }
        }
        return out
    }

    private static func stripComment<S: StringProtocol>(_ line: S) -> String {
        if let range = line.range(of: "//") {
            return String(line[..<range.lowerBound])
        }
        return String(line)
    }

    private struct ParsedInclude {
        let url: URL
        let optional: Bool
    }

    private static func parseInclude(_ line: String, relativeTo directory: URL) -> ParsedInclude? {
        let optional: Bool
        let body: String
        if line.hasPrefix("#include?") {
            optional = true
            body = String(line.dropFirst("#include?".count))
        } else if line.hasPrefix("#include") {
            optional = false
            body = String(line.dropFirst("#include".count))
        } else {
            return nil
        }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        let path = String(trimmed.dropFirst().dropLast())
        let resolved: URL
        if path.hasPrefix("/") {
            resolved = URL(fileURLWithPath: path)
        } else {
            resolved = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        }
        return ParsedInclude(url: resolved, optional: optional)
    }

    private static func parseAssignment(_ line: String) -> (String, String)? {
        guard let equalsIndex = line.firstIndex(of: "=") else { return nil }
        let left = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        let right = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return nil }
        if left.contains(where: { $0.isWhitespace && $0 != " " }) { return nil }
        return (left, right)
    }
}

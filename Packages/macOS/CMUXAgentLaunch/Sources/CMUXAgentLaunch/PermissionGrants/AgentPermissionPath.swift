import Darwin
import Foundation

/// Path handling for grants. Every check fails closed: a path it can't
/// place with certainty never matches.
enum AgentPermissionPath {
    /// Absolute, standardized, with symlinks resolved through the deepest
    /// existing ancestor, so a file that doesn't exist yet compares like its
    /// existing directory.
    static func canonical(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        var existing = URL(fileURLWithPath: expanded).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        guard let path = canonical(path), let root = canonical(root) else { return false }
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// Lexically clean absolute components (no empty or `.`), or `nil` when
    /// the path has a `..` component.
    static func components(ofAbsolute path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains("..") else { return nil }
        return parts.filter { $0 != "." }
    }

    static func join(_ components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    /// The absolute path a tool call names: `path` itself, or `path` under
    /// an absolute `cwd`. `nil` for `~` paths and any `..` component.
    static func requestPath(_ path: String, cwd: String?) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~"),
              !AgentPermissionText.containsInvisibleOrControl(path) else { return nil }
        let full: String
        if path.hasPrefix("/") {
            full = path
        } else {
            guard let cwd, let base = components(ofAbsolute: cwd) else { return nil }
            full = join(base) + "/" + path
        }
        return components(ofAbsolute: full).map(join)
    }

    /// The components of `path` below `root`, when the path reaches the
    /// root and no component below it is a symlink (dangling or not).
    ///
    /// Symlinks above the root are how the root itself is reached (macOS
    /// `/tmp`), so only the part below the root is checked with `lstat`.
    static func componentsBelow(root canonicalRoot: String, path: String) -> [String]? {
        guard let parts = components(ofAbsolute: path) else { return nil }
        for split in 0...parts.count where canonical(join(Array(parts[..<split]))) == canonicalRoot {
            let below = Array(parts[split...])
            var current = join(Array(parts[..<split]))
            for component in below {
                current = current == "/" ? "/" + component : current + "/" + component
                var info = stat()
                if lstat(current, &info) != 0 {
                    // Nothing below a missing component exists either.
                    guard errno == ENOENT else { return nil }
                    break
                }
                if info.st_mode & S_IFMT == S_IFLNK { return nil }
            }
            return below
        }
        return nil
    }

    private static let protectedComponents: Set<String> = [".git", ".claude"]
    private static let protectedNames: Set<String> = [".mcp.json", ".envrc"]
    private static let protectedHomeFiles = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"]
    private static let protectedHomeTrees = [".ssh", "Library", ".config/cmux", ".cmuxterm"]

    /// Paths no grant ever answers for: git internals, agent settings,
    /// shell startup files, credentials, and cmux's own configuration.
    /// Compared case-insensitively, like the default macOS file system.
    static func isProtected(_ path: String, home: String) -> Bool {
        let candidates = [path, canonical(path)].compactMap { $0?.lowercased() }
        let homes = Set([home, canonical(home)].compactMap { $0?.lowercased() })
        for candidate in candidates {
            let parts = candidate.split(separator: "/").map(String.init)
            if parts.contains(where: protectedComponents.contains) { return true }
            if let last = parts.last, protectedNames.contains(last) { return true }
            for home in homes {
                if protectedHomeFiles.contains(where: { candidate == home + "/" + $0 }) { return true }
                for tree in protectedHomeTrees {
                    let root = home + "/" + tree.lowercased()
                    if candidate == root || candidate.hasPrefix(root + "/") { return true }
                }
            }
        }
        return false
    }
}

/// Text checks shared by rules, reasons and scopes.
enum AgentPermissionText {
    /// Whether `text` has a Unicode control (Cc) or format (Cf) character:
    /// newlines, bidi overrides, zero-width characters.
    static func containsInvisibleOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
        }
    }

    /// A reason on one line with single spaces, or `nil` when it carries
    /// control or format characters.
    static func sanitizedReason(_ reason: String) -> String? {
        let collapsed = reason.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return containsInvisibleOrControl(collapsed) ? nil : collapsed
    }
}

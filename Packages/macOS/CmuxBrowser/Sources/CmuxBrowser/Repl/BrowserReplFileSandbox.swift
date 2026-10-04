import Darwin
import Foundation

/// A Node-style file system error for the REPL `fs` global.
public struct BrowserReplFileSystemError: Error, Equatable, Sendable {
    /// Node error code, for example `ENOENT` or `EACCES`.
    public let code: String
    /// Human-readable message, Node style (`"ENOENT: no such file or directory, open 'x'"`).
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    static func escape(_ path: String) -> Self {
        Self(code: "EACCES", message: "EACCES: permission denied, path is outside the REPL working directory '\(path)'")
    }
}

/// Resolves REPL `fs` paths against a session's working directory.
///
/// Relative paths resolve against `root`. Absolute paths and `..` segments
/// are accepted only when the result, after resolving symbolic links, stays
/// inside `root`. An operation on a link itself (`rm`, `rename`, `lstat`)
/// checks only the link's parent directories, so a link that points outside
/// the root can be removed or moved but never read or written through.
/// Files the browser downloaded for this session are also
/// readable (never writable), because `download.path()` hands the script a
/// path outside the working directory.
public struct BrowserReplFileSandbox: Sendable {
    /// Whether a path is being read or modified.
    public enum Access: Sendable {
        case read
        case write
    }

    /// Canonical root (symbolic links resolved).
    public let root: String
    private var readableFiles: Set<String> = []

    /// Creates a sandbox rooted at `root`. The directory need not exist yet.
    public init(root: String) {
        self.root = Self.canonicalize(Self.lexicallyNormalized(root))
    }

    /// Why `root` cannot be a REPL working directory, or `nil` when it can.
    ///
    /// `/`, the home directory and any directory containing it would give
    /// scripts every file the user owns, so they are refused. The reason is
    /// written for the agent running the command and says what to do.
    public static func rootRejection(_ root: String, homeDirectory: String) -> String? {
        let canonical = canonicalize(lexicallyNormalized(root))
        let home = canonicalize(lexicallyNormalized(homeDirectory))
        guard canonical == "/" || canonical == home || home.hasPrefix(canonical + "/") else { return nil }
        let subject = canonical == home ? "the home directory '\(root)'" : "'\(root)'"
        return "refusing to use \(subject) as the REPL working directory: fs would reach every file in it. "
            + "cd to a project or scratch directory (for example cd \"$(mktemp -d)\") and run the command again"
    }

    /// Allows reading one file outside the root, for example a finished download.
    public mutating func allowReading(_ path: String) {
        readableFiles.insert(Self.canonicalize(Self.lexicallyNormalized(path)))
    }

    /// Whether `canonicalPath` is a file outside the root allowed for reading.
    func allowsReading(_ canonicalPath: String) -> Bool {
        readableFiles.contains(canonicalPath)
    }

    /// Keeps the files `other` allowed, when a session moves to a new root.
    public mutating func inheritReadableFiles(from other: BrowserReplFileSandbox) {
        readableFiles.formUnion(other.readableFiles)
    }

    /// Resolves `path` for `access`.
    /// - Returns: Canonical absolute path.
    /// - Throws: `EINVAL` for an empty path, `EACCES` when the path leaves the root.
    /// - Parameter followingLastLink: `true` (reading or writing through the
    ///   path) resolves every symbolic link, so a link inside the root that
    ///   points outside it is refused. `false` (acting on the entry itself,
    ///   as `rm`, `rename` and `lstat` do) resolves links in the parent
    ///   directories only and keeps the last component as named, so the
    ///   result is the link, wherever it points.
    /// - Parameter additionalRoots: Extra canonical roots that count as inside
    ///   for this call (`fs` also reaches the user's temporary directory).
    public func resolve(
        _ path: String,
        for access: Access,
        followingLastLink: Bool = true,
        additionalRoots: [String] = []
    ) throws -> String {
        guard !path.isEmpty, !path.contains("\u{0}") else {
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: invalid path '\(path)'")
        }
        let roots = [root] + additionalRoots
        let normalized = Self.lexicallyNormalized(path.hasPrefix("/") ? path : root + "/" + path)
        let followed = Self.canonicalize(normalized)
        var candidates = [followed]
        if !followingLastLink {
            // The entry itself, under its canonical parent. A root reached
            // through a link to it (or `.`) still names the root.
            candidates = [Self.entryPath(normalized)]
            if roots.contains(followed) { candidates.append(followed) }
        }
        for canonical in candidates {
            for candidate in roots
            where canonical == candidate || canonical.hasPrefix(candidate == "/" ? "/" : candidate + "/") {
                return canonical
            }
            if access == .read, readableFiles.contains(canonical) {
                return canonical
            }
        }
        throw BrowserReplFileSystemError.escape(path)
    }

    /// `path` (absolute, normalized) with symbolic links resolved in its
    /// parent directories only.
    static func entryPath(_ path: String) -> String {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        let parent = canonicalize(slash == path.startIndex ? "/" : String(path[..<slash]))
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Removes `.` and `..` segments and duplicate slashes without touching the disk.
    /// Why a REPL navigation (`tab.navigate`, `tabs.open`) to `urlString`
    /// may not load, before any domain policy, or nil.
    ///
    /// The browser loads a `file:` URL with read access to its directory, so
    /// the page could read files the session's `fs` cannot. Only web URLs
    /// (`http`, `https`), `about:`, `data:` and `blob:` load, and `file:`
    /// URLs of a file strictly inside one of `roots` (the session's working
    /// and temporary directories), judged by the path as written (`..`
    /// resolved lexically) and refused when any part of it below the root
    /// is a symbolic link, which WebKit would follow out of the root. Any
    /// other scheme (cmux's internal ones, `javascript:`) is refused. A
    /// string without a scheme is left to the driver, which reads it as a
    /// web address; one that looks like a path is refused.
    public static func navigationRefusal(_ urlString: String, roots: [String]) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
                return "\(urlString) is a local path; use a file: URL inside the session's directories"
            }
            return nil
        }
        switch scheme {
        case "http", "https", "about", "data", "blob":
            return nil
        case "file":
            let host = url.host(percentEncoded: false) ?? ""
            guard host.isEmpty || host.lowercased() == "localhost" else {
                return "\(urlString) names a file on another host"
            }
            let path = lexicallyNormalized(url.path(percentEncoded: false))
            for root in roots.flatMap(aliases(of:)) where path.hasPrefix(root + "/") {
                var current = root
                for part in path.dropFirst(root.count).split(separator: "/") {
                    current += "/" + part
                    var info = stat()
                    if lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                        return "\(urlString) goes through the symbolic link \(current), which may lead outside the session's directories"
                    }
                }
                return nil
            }
            return "a REPL session loads only files inside its working or temporary directory (\(roots.joined(separator: ", "))), not \(urlString)"
        default:
            return "a REPL session loads only http, https, about:, data: and blob: URLs and files inside its own directories, not \(scheme): URLs"
        }
    }

    /// `root` and, for a root under `/private`, the same path through the
    /// system's `/var`, `/tmp` and `/etc` links, as a file URL may name it.
    private static func aliases(of root: String) -> [String] {
        let normalized = lexicallyNormalized(root)
        guard normalized.hasPrefix("/private/") else { return [normalized] }
        return [normalized, String(normalized.dropFirst("/private".count))]
    }

    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves symbolic links in the longest existing prefix of an absolute,
    /// normalized path and appends the remaining (not yet created) components.
    static func canonicalize(_ path: String) -> String {
        var existing = path
        var remainder: [String] = []
        while true {
            if let resolved = realPath(existing) {
                let tail = remainder.reversed().joined(separator: "/")
                if tail.isEmpty { return resolved }
                return resolved == "/" ? "/" + tail : resolved + "/" + tail
            }
            var info = stat()
            if lstat(existing, &info) == 0 {
                // A dangling symbolic link: writing through it would create
                // its target, which may be anywhere. Report no canonical path.
                return danglingLinkMarker
            }
            guard existing != "/", let slash = existing.lastIndex(of: "/") else {
                return path
            }
            remainder.append(String(existing[existing.index(after: slash)...]))
            existing = slash == existing.startIndex ? "/" : String(existing[..<slash])
        }
    }

    /// Never a prefix of a real root, so resolution through a dangling link fails.
    static let danglingLinkMarker = "\u{0}dangling-link"

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

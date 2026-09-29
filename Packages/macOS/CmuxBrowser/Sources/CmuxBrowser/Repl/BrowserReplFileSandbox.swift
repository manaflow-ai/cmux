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
/// inside `root`. Files the browser downloaded for this session are also
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

    /// Allows reading one file outside the root, for example a finished download.
    public mutating func allowReading(_ path: String) {
        readableFiles.insert(Self.canonicalize(Self.lexicallyNormalized(path)))
    }

    /// Keeps the files `other` allowed, when a session moves to a new root.
    public mutating func inheritReadableFiles(from other: BrowserReplFileSandbox) {
        readableFiles.formUnion(other.readableFiles)
    }

    /// Resolves `path` for `access`.
    /// - Returns: Canonical absolute path.
    /// - Throws: `EINVAL` for an empty path, `EACCES` when the path leaves the root.
    /// - Parameter additionalRoots: Extra canonical roots that count as inside
    ///   for this call (the ChatGPT dialect's `node:fs` also reaches the
    ///   user's temporary directory).
    public func resolve(_ path: String, for access: Access, additionalRoots: [String] = []) throws -> String {
        guard !path.isEmpty, !path.contains("\u{0}") else {
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: invalid path '\(path)'")
        }
        let joined = path.hasPrefix("/") ? path : root + "/" + path
        let canonical = Self.canonicalize(Self.lexicallyNormalized(joined))
        for candidate in [root] + additionalRoots
        where canonical == candidate || canonical.hasPrefix(candidate == "/" ? "/" : candidate + "/") {
            return canonical
        }
        if access == .read, readableFiles.contains(canonical) {
            return canonical
        }
        throw BrowserReplFileSystemError.escape(path)
    }

    /// Removes `.` and `..` segments and duplicate slashes without touching the disk.
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

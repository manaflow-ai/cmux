import Darwin
public import Foundation

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
    /// web address; one that looks like a path is refused. So is a file
    /// `secrets.load` read, by its identity under any name
    /// (``BrowserReplSecretSources``).
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
                if BrowserReplSecretSources.shared.contains(path: path) {
                    return "\(urlString) is a file secrets.load read (under this or another name); a tab would show its values unmasked"
                }
                return nil
            }
            return "a REPL session loads only files inside its working or temporary directory (\(roots.joined(separator: ", "))), not \(urlString)"
        default:
            return "a REPL session loads only http, https, about:, data: and blob: URLs and files inside its own directories, not \(scheme): URLs"
        }
    }

    /// Why a session may not read or act on a tab that shows `url`, or nil.
    ///
    /// A local file outside `roots` (the session's working and temporary
    /// directories), by the rule ``navigationRefusal(_:roots:)`` applies to
    /// the session's own navigations, is refused: the tab may be a user's
    /// that shows a file the session's `fs` cannot read, and the browser let
    /// its page read that file's directory. So is any other document of a
    /// local file's origin (`documentOrigin` `file://`: an `about:blank` or
    /// `data:` document a file page wrote), whose maker cannot be told; the
    /// caller passes `documentOrigin` only for tabs the session did not
    /// create, whose file pages no session check stood before.
    public static func localPageRefusal(url: String, documentOrigin: String?, roots: [String]) -> String? {
        if URL(string: url)?.scheme?.lowercased() == "file" {
            guard let reason = navigationRefusal(url, roots: roots) else { return nil }
            return "the tab shows the local file \(url), which a REPL session may not read: \(reason)"
        }
        if documentOrigin?.lowercased() == "file://" {
            return "the tab shows \(url.isEmpty ? "a document" : url) of a local file's origin, which a REPL session may not read; open files inside the session's directories with tabs.open"
        }
        return nil
    }

    /// WebKit content rules that keep pages in a session's tabs from loading
    /// local files outside `roots` (the session's working and temporary
    /// directories) as subresources or child frames, whatever read access
    /// their web process holds.
    ///
    /// Every `file:` load is blocked, then one under a root's path (also by
    /// its `/var`, `/tmp` alias, and with the `localhost` host) is let
    /// through, matched case-sensitively on the URL as WebKit spells it
    /// (percent-encoded). A path that spells a root another way is blocked,
    /// which only refuses more. An encoded slash (`%2F`) is blocked again:
    /// a file name with one would name a path the rule did not judge. A
    /// link below a root is resolved by WebKit's own read-access check,
    /// which refuses a file outside the directory it granted. Main-frame
    /// documents are left to the navigation checks, which report the block.
    public static func contentRules(roots: [String]) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        func add(_ filter: String, _ action: String, caseSensitive: Bool = false) {
            for var trigger in [
                ["url-filter": filter, "resource-type": fileSubresources] as [String: Any],
                ["url-filter": filter, "resource-type": ["document"], "load-context": ["child-frame"]],
            ] {
                if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
                rules.append(["trigger": trigger, "action": ["type": action]])
            }
        }
        add("^file:", "block")
        for root in Set(roots.flatMap(aliases(of:))) where root != "/" {
            let spelled = URL(fileURLWithPath: root, isDirectory: true).absoluteString
            guard spelled.hasPrefix("file:///") else { continue }
            let path = escapeForContentRule(String(spelled.dropFirst("file://".count)))
            add("^file://" + path, "ignore-previous-rules", caseSensitive: true)
            add("^file://localhost" + path, "ignore-previous-rules", caseSensitive: true)
        }
        add("^file:.*%2[Ff]", "block")
        return rules
    }

    private static let fileSubresources = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket", "other"]

    private static func escapeForContentRule(_ text: String) -> String {
        var out = ""
        for character in text {
            if ".+?^${}()|[]\\*".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Held by every REPL `fs.rename` around its `renameat`, by `copyFile`
    /// while it checks and renames its staging file into place, and by a
    /// file navigation from its last check until the browser took its read
    /// access (``withPinnedFileAccess(_:roots:_:)``): no REPL session (this
    /// one included, from its own thread) moves an entry in between.
    /// `rename` is the only `fs` operation that can put a link, or a
    /// directory that holds one, at a path; `copyFile` renames only the
    /// regular file it wrote, and the others make regular files and
    /// directories or remove entries.
    static let pathChangeLock = NSLock()

    /// Runs `load`, which must start the browser's load of the file `url`
    /// before it returns, with the directory to grant the page read access
    /// to: the session root that holds the file.
    ///
    /// The browser loads a file by path and resolves the read-access
    /// directory's links when it grants it, so a check that runs before
    /// the load can be raced: another REPL session sharing the directory
    /// could rename a link in for a checked directory. Here, while no REPL
    /// `fs.rename` can run (``pathChangeLock``), the file's path is checked
    /// again (``navigationRefusal(_:roots:)``), the root must still be the
    /// directory the session named (same identity, no link on its path),
    /// and the browser is given that root. A link swapped in below it later
    /// leads nowhere outside it: WebKit refuses a file outside the directory
    /// it granted, as it resolved it then.
    /// - Throws: `blocked` when the file is outside the roots or a root was
    ///   moved or replaced.
    public static func withPinnedFileAccess<T>(_ url: String, roots: [BrowserReplFileRoot], _ load: (URL) throws -> T) throws -> T {
        try pathChangeLock.withLock {
            if let reason = navigationRefusal(url, roots: roots.map(\.path)) {
                throw BrowserReplDriverError(code: "blocked", message: "\(url) is blocked: \(reason)")
            }
            guard let file = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BrowserReplDriverError(code: "invalid", message: "Invalid URL")
            }
            let path = lexicallyNormalized(file.path(percentEncoded: false))
            guard let root = roots.first(where: { root in aliases(of: root.path).contains { path.hasPrefix($0 + "/") } }) else {
                throw BrowserReplDriverError(code: "blocked", message: "\(url) is blocked: it is not inside the session's directories")
            }
            guard root.isStillInPlace else {
                throw BrowserReplDriverError(
                    code: "blocked",
                    message: "\(url) is blocked: the session's directory \(root.path) was moved or replaced since the session began; start a new session there"
                )
            }
            return try load(URL(fileURLWithPath: root.path, isDirectory: true))
        }
    }

    /// Whether `path`, normalized without the file system, lies strictly
    /// inside one of `roots` (also through a root's `/var`, `/tmp` alias).
    static func isLexicallyInside(_ path: String, roots: [String]) -> Bool {
        let normalized = lexicallyNormalized(path)
        return roots.contains { root in aliases(of: root).contains { normalized.hasPrefix($0 + "/") } }
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

/// A directory a REPL session's tabs may show local files from: its
/// canonical path and the identity of the directory there when the session
/// named it.
public struct BrowserReplFileRoot: Sendable, Equatable {
    public let path: String
    let device: Int64?
    let inode: UInt64?

    /// Whether `path` still names, with no link on the way, the directory
    /// that was there when this was made.
    var isStillInPlace: Bool {
        guard let device, let inode,
              BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized(path)) == path else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && Int64(info.st_dev) == device && UInt64(info.st_ino) == inode
    }

    /// Reads the identity of the directory at `path` now.
    public init(path: String) {
        self.path = path
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
        } else {
            device = nil
            inode = nil
        }
    }
}

/// The files any session's `secrets.load` read, by identity
/// (``BrowserReplFileIdentity``): no session's tab loads one from then on
/// (``BrowserReplFileSandbox/navigationRefusal(_:roots:)``), under any name,
/// while the file exists. Value masking covers what `fs` reads back, but a
/// tab renders the file as pixels no mask covers, and its page scripts
/// read it.
///
/// The set is shared by every session for the app's life, so it holds at
/// most ``maximumSources`` files. A protection ends only when its file is
/// gone under every name (no tab can load it then); not when the session
/// that loaded it ends, since a value it typed stays masked in text after
/// that but a capture masks it only on the secret's domains, never in a
/// `file:` page. Past the bound, once the files that are gone are dropped,
/// a new protection is refused and `secrets.load` fails with nothing read.
final class BrowserReplSecretSources: @unchecked Sendable {
    static let shared = BrowserReplSecretSources()

    /// The most files protected at once (4,096 for the app).
    let maximumSources: Int
    private let lock = NSLock()
    private var identities: Set<BrowserReplFileIdentity> = []

    init(maximumSources: Int = 4096) {
        self.maximumSources = maximumSources
    }

    /// Protects `identity`. The caller holds
    /// ``BrowserReplFileSandbox/pathChangeLock``, which a file navigation
    /// holds from its check until its load started
    /// (``BrowserReplFileSandbox/withPinnedFileAccess(_:roots:_:)``), and has
    /// held it since it opened the file: `secrets.load`'s read tells it
    /// the identity in the same hold as the open
    /// (``BrowserReplFileSystem``'s `readFile` with `opened`), so a
    /// navigation runs wholly before the open or after the protection,
    /// never between them.
    ///
    /// - Throws: `invalid` when ``maximumSources`` files that still exist
    ///   are protected and `identity` is not one of them.
    func protect(_ identity: BrowserReplFileIdentity) throws {
        try lock.withLock {
            guard !identities.contains(identity) else { return }
            if identities.count >= maximumSources {
                identities = identities.filter(\.exists)
            }
            guard identities.count < maximumSources else {
                throw BrowserReplFileSystemError(
                    code: "invalid",
                    message: "cmux protects at most \(maximumSources) files that secrets.load read, for every session together, and that many still exist; remove secrets files that are no longer needed, or set the secrets with secrets.set"
                )
            }
            identities.insert(identity)
        }
    }

    /// Whether the file at `path` (links followed) is one `secrets.load` read.
    func contains(path: String) -> Bool {
        guard let identity = BrowserReplFileIdentity(path: path) else { return false }
        return contains(identity)
    }

    /// Whether `identity` is a file `secrets.load` read.
    func contains(_ identity: BrowserReplFileIdentity) -> Bool {
        lock.withLock { identities.contains(identity) }
    }
}

/// A file by its device and inode, which a rename or another hard link
/// keeps.
struct BrowserReplFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }

    /// The identity of the file at `path`, links followed, or nil.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    /// Whether the file may still exist: false only when its volume says
    /// no object has this identity (`fsgetpath` fails with `ENOENT`, as for
    /// a file removed under every name). A volume that cannot tell counts
    /// as yes.
    var exists: Bool {
        var volume = fsid_t(val: (Int32(truncatingIfNeeded: Int64(bitPattern: device)), 0))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { fsgetpath($0.baseAddress, $0.count, &volume, inode) }
        return length >= 0 || errno != ENOENT
    }
}

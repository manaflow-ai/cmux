import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Default-deny path scoping for the files family (c4-files.md section 3).
/// Built per request from the configuration and the provider's roots: every
/// root and every request path is canonicalized with `realpath(3)`, and a
/// path is served only when its canonical form is inside a canonical root,
/// so a symlink that leaves every root is refused wherever it sits.
public struct MobileFilePolicy: Sendable {
    /// A root after canonicalization.
    public struct Root: Hashable, Sendable {
        public var root: MobileFileRoot
        /// Canonical absolute path.
        public var path: String
    }

    /// A request path that passed the policy.
    public struct Resolved: Hashable, Sendable {
        /// Canonical absolute path.
        public var path: String
        public var root: Root
    }

    /// Names never served below a root, at any depth, compared without case
    /// (APFS is usually case-insensitive, so `.SSH` opens `.ssh`).
    public static let deniedNames: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc", ".pgpass", "keychains",
        "id_rsa", "id_ecdsa", "id_ed25519", "id_dsa",
    ]

    public static func isDenied(_ name: String) -> Bool {
        deniedNames.contains(name.lowercased())
    }
    /// Trees under home that may never be (or contain) a root.
    public static let protectedHomeTrees = ["Library", ".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
    public static let inboxID = "inbox"
    static let maxPathBytes = 4096

    public let roots: [Root]
    public let configuration: MobileFilesConfiguration
    private let home: String

    public init(configuration: MobileFilesConfiguration, roots: [MobileFileRoot]) {
        self.configuration = configuration
        let home = Self.canonicalize(configuration.homeDirectory.path) ?? configuration.homeDirectory.path
        self.home = home
        let inbox = MobileFileRoot(id: Self.inboxID, name: configuration.inbox.lastPathComponent,
                                   url: configuration.inbox, writable: true)
        var seen: Set<String> = []
        var accepted: [Root] = []
        for root in [inbox] + roots {
            guard let path = Self.canonicalize(root.url.path), Self.isAllowedRoot(path, home: home),
                  !seen.contains(path) else { continue }
            seen.insert(path)
            accepted.append(Root(root: root, path: path))
        }
        self.roots = accepted
    }

    /// The inbox root, when its location is allowed.
    public var inbox: Root? { roots.first { $0.root.id == Self.inboxID } }

    // MARK: Resolution

    /// Resolves a path that must exist (download, list).
    public func resolveExisting(_ raw: String) throws(MobileDaemonError) -> Resolved {
        let resolved = try resolve(raw)
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else { throw .filesNotFound() }
        return resolved
    }

    /// Resolves an existing directory under a writable root (`dest.kind = path`).
    public func resolveWritableDirectory(_ raw: String) throws(MobileDaemonError) -> Resolved {
        let resolved = try resolve(raw)
        guard resolved.root.root.writable else { throw .filesForbidden("this directory is read-only for phones") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MobileDaemonError(code: "files.dest_invalid", message: "the destination is not a directory")
        }
        return resolved
    }

    /// Creates the inbox (0700) when missing and returns its canonical path.
    public func ensureInbox() throws(MobileDaemonError) -> Resolved {
        guard let inbox else { throw .filesForbidden("the inbox location is not allowed") }
        do {
            try FileManager.default.createDirectory(atPath: inbox.path, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MobileDaemonError(code: "files.dest_invalid", message: "the inbox could not be created")
        }
        // Re-resolve: the directory now exists, so a symlink planted on the way is caught.
        let again = try resolve(inbox.path)
        guard again.root.root.id == Self.inboxID else { throw .filesForbidden() }
        return again
    }

    /// Canonicalizes and scopes `raw`. Outside every root (or a denied name)
    /// is `files.forbidden` whether or not the path exists.
    public func resolve(_ raw: String) throws(MobileDaemonError) -> Resolved {
        guard !raw.isEmpty, raw.utf8.count <= Self.maxPathBytes, !raw.contains("\0") else {
            throw .filesInvalid("bad path")
        }
        let expanded: String
        if raw == "~" {
            expanded = configuration.homeDirectory.path
        } else if raw.hasPrefix("~/") {
            expanded = configuration.homeDirectory.path + String(raw.dropFirst(1))
        } else if raw.hasPrefix("/") {
            expanded = raw
        } else {
            throw .filesInvalid("paths are absolute or start with ~/")
        }
        guard let canonical = Self.canonicalize(expanded) else { throw .filesForbidden() }
        guard let root = roots.filter({ Self.isInside(canonical, $0.path) }).max(by: { $0.path.count < $1.path.count }) else {
            throw .filesForbidden()
        }
        let below = canonical.dropFirst(root.path.count).split(separator: "/")
        guard !below.contains(where: { Self.isDenied(String($0)) }) else {
            throw .filesForbidden("this name is never shared")
        }
        return Resolved(path: canonical, root: root)
    }

    // MARK: Names

    /// A safe single path component for an uploaded file.
    public static func sanitizedName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { $0 != "/" && $0 != ":" && $0.value >= 0x20 && $0.value != 0x7F }
        var clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.utf8.count > 255 {
            let ext = (clean as NSString).pathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
            var base = String((clean as NSString).deletingPathExtension)
            while base.utf8.count + suffix.utf8.count > 255 { base.removeLast() }
            clean = base + suffix
        }
        if clean.isEmpty { return "file" }
        return isDenied(clean) ? "_" + clean : clean
    }

    /// Creates a new empty file in `directory` named `name`, `name (2).ext`,
    /// ... with an exclusive create, so nothing is ever overwritten.
    public static func createUniqueFile(in directory: String, name: String) throws(MobileDaemonError) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 1...1000 {
            let candidate = n == 1 ? name : "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let path = directory + "/" + candidate
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                close(fd)
                return path
            }
            guard errno == EEXIST else { break }
        }
        throw MobileDaemonError(code: "files.dest_invalid", message: "could not create the file")
    }

    // MARK: Canonical paths

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func isAllowedRoot(_ path: String, home: String) -> Bool {
        let lowered = path.lowercased()
        let home = home.lowercased()
        guard lowered != home, lowered.hasPrefix(home + "/") else { return false }
        return !protectedHomeTrees.contains { isInside(lowered, home + "/" + $0.lowercased()) }
    }

    /// `realpath(3)` of the longest existing prefix plus the missing tail.
    /// Nil when the tail has `.` or `..`, or a component exists but cannot be
    /// resolved (a dangling symlink, no permission).
    static func canonicalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        var index = components.count
        while index >= 0 {
            let prefix = "/" + components[0..<index].joined(separator: "/")
            if let real = realPath(prefix) {
                let tail = components[index...]
                if let next = tail.first {
                    var info = stat()
                    guard lstat(real == "/" ? "/" + next : real + "/" + next, &info) != 0, errno == ENOENT else { return nil }
                }
                guard !tail.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
                return tail.isEmpty ? real : (real == "/" ? "" : real) + "/" + tail.joined(separator: "/")
            }
            index -= 1
        }
        return nil
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

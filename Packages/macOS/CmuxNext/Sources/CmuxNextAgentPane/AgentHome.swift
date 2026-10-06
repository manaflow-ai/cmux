import Darwin
public import Foundation

/// The agent-home folders (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): a workspace without a folder (the
/// default Home workspace) gives its new agent chats `<base>/<workspace-id>`, where `base` is
/// `~/Library/Application Support/cmux/agent-home`. It is the chat cwd and the workspace's only
/// root, made with mode 0700 on first use. There is never a fallback to the home folder: a base
/// that is not canonical, a workspace id that is not safe, or a symlink anywhere in the path gives
/// no folder, and the relay refuses the chat (`transport.path_invalid`).
///
/// A close never deletes a folder (chat files may be in it). A History reopen moves it to the new
/// workspace id (``move(from:to:)``); an expired History entry sends it to the Trash
/// (``trash(_:using:)``), never a hard delete. Everything here touches the disk: call it off the
/// main thread, except the one rename of a reopen.
public nonisolated struct AgentHome: Sendable, Equatable {
    /// The canonical folder that holds every workspace's folder.
    public let base: String

    public init(base: String) {
        self.base = base
    }

    /// `~/Library/Application Support/cmux/agent-home`; nil when the system names no
    /// Application Support folder.
    public static var standard: AgentHome? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return AgentHome(base: support.appendingPathComponent("cmux/agent-home", isDirectory: true).path)
    }

    /// A workspace id that names a folder: 1 to 128 characters of `[A-Za-z0-9_-]` (the app's
    /// workspace keys are lowercased UUIDs, the store's home workspace is `home`).
    public static func isSafeID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }

    /// `path` in canonical form when it names an existing folder (a "Choose Folder…" pick), else
    /// nil. Touches the disk.
    public static func canonicalFolder(_ path: String) -> String? {
        guard let canonical = AcpmuxPathPolicy.canonical(path), AcpmuxPathPolicy.isDirectory(canonical) else { return nil }
        return canonical
    }

    /// Whether `path` is `/`, the home folder `home` or a folder above it (by path components,
    /// after `~` and `..` are resolved as text). Such a folder is never a chat's implicit folder.
    public static func isHomeOrAbove(_ path: String, home: String? = NSHomeDirectory()) -> Bool {
        let standard = (path as NSString).standardizingPath
        guard standard != "/" else { return true }
        guard let home = home.map({ ($0 as NSString).standardizingPath }) else { return false }
        return AcpmuxPathPolicy.contains(root: standard, path: home)
    }

    /// The folder of workspace `id`, nil for an id that is not safe. Does not touch the disk.
    public func path(for id: String) -> String? {
        guard Self.isSafeID(id) else { return nil }
        return base + "/" + id
    }

    /// The canonical folder of workspace `id`, made (mode 0700, owned by this user) when missing.
    /// Nil when the id is not safe, the base is not absolute and canonical, a component of the path
    /// is a symlink or not a folder, or the folder belongs to another user.
    public func ensure(_ id: String) -> String? {
        guard let path = path(for: id), Self.makePrivateFolders(path, from: base) else { return nil }
        // Every component is checked: the filesystem's own spelling must be the path itself.
        guard AcpmuxPathPolicy.canonical(path) == path else { return nil }
        return path
    }

    /// Moves workspace `old`'s folder to workspace `new` (a History reopen): one rename that never
    /// replaces an existing folder. False when either id is not safe, the source is missing, a
    /// symlink or not a folder, or the target exists.
    public func move(from old: String, to new: String) -> Bool {
        guard old != new, let source = path(for: old), let target = path(for: new),
              AcpmuxPathPolicy.canonical(base) == base, Self.isRealFolder(source) else { return false }
        return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0
    }

    /// Sends workspace `id`'s folder to the Trash with `trash` (`FileManager.trashItem`): never a
    /// hard delete. False when there is nothing to trash or the path is a symlink.
    public func trash(_ id: String, using trash: (URL) throws -> Void) -> Bool {
        guard let path = path(for: id), AcpmuxPathPolicy.canonical(base) == base, Self.isRealFolder(path) else { return false }
        do {
            try trash(URL(fileURLWithPath: path, isDirectory: true))
            return true
        } catch {
            return false
        }
    }

    /// Whether `path` is a folder itself (lstat: a symlink is not), owned by this user.
    static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    /// Walks `path` from `/`: an existing component must be a real folder (never a symlink); the
    /// missing ones at or under `base` are made with mode 0700. The last one is made private again
    /// when its mode is looser. False on the first component that breaks a rule.
    static func makePrivateFolders(_ path: String, from base: String) -> Bool {
        guard base.hasPrefix("/"), path.hasPrefix(base + "/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let baseDepth = base.split(separator: "/").count
        var current = ""
        for (index, part) in parts.enumerated() {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) != 0 {
                // Only the base's own folders and the workspace folder may be made here.
                guard errno == ENOENT, index + 1 >= baseDepth - 1, mkdir(current, 0o700) == 0 || errno == EEXIST,
                      lstat(current, &info) == 0 else { return false }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 { return false }
        return true
    }
}

/// The agent-home folder one pane's new chats get when its workspace has no folder.
public nonisolated struct AgentHomeFill: Sendable, Equatable {
    public var home: AgentHome
    public var workspace: String

    public init(home: AgentHome, workspace: String) {
        self.home = home
        self.workspace = workspace
    }
}

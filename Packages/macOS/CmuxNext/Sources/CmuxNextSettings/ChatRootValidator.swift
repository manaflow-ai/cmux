public import Foundation
import CmuxNextCompat

/// Refuses chat roots before accessing protected folders. Keep the guarded lists in sync with
/// cmux-tui/crates/acpmux/src/protected_folders.rs. No folder contents are ever read.
public nonisolated struct ChatRootValidator: Sendable {
    public let home: String
    private let homes: [String]
    private var readLink: @Sendable (String) -> String?
    /// A path's identity without following a final link (`lstat`).
    private var identityOf: @Sendable (String) -> Identity? = { ChatRootValidator.identity($0) }

    /// Inject a home and a readlink-only resolver to validate without touching a user's files.
    public init(home: String = NSHomeDirectory(), readLink: @escaping @Sendable (String) -> String? = {
        try? FileManager.default.destinationOfSymbolicLink(atPath: $0)
    }) {
        self.home = home
        self.readLink = readLink
        homes = [home, Self.resolveHome(home, readLink: readLink)]
    }

    /// A localized refusal, or nil for an absolute, unprotected path.
    public func refusal(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            return SettingsText.keyed("settings.chats.root.relative", "Use an absolute folder path.").text
        }
        // Check the spelling before even readlink: resolving a protected descendant would read it.
        if let reason = guarded(path, final: true) { return reason }
        var parts = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !parts.isEmpty {
            let part = parts.removeFirst()
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let reason = guarded(candidate, final: parts.isEmpty) { return reason }
            if let target = readLink(candidate) {
                links += 1
                guard links <= 40 else {
                    return SettingsText.keyed("settings.chats.root.symlink", "This folder has too many symbolic links.").text
                }
                if target.hasPrefix("/") { resolved = [] }
                parts = target.split(separator: "/").map(String.init) + parts
            } else {
                resolved.append(part)
            }
        }
        return guarded("/" + resolved.joined(separator: "/"), final: true)
    }

    /// A copy for one batch of checks over paths that share their folders (one picker answer): each
    /// folder's link (`readlink`) and identity (`lstat`) is read once for the batch, however many of
    /// its paths pass through that folder, and the protected folders once rather than on every path.
    /// The project pickers checked each of 40 folders' Git files this way, each check walking every
    /// folder from `/` twice, which held three cores for seconds on a loaded Mac (2026-10-21). Answers
    /// are the same as the validator's while the disk does not change; keep a batch only for one
    /// answer, never across them. A folder swapped for a link during the answer is seen at its
    /// first check: the same window an unbatched check has between checking a path and reading it.
    public func batch() -> ChatRootValidator {
        let lookups = BatchLookups()
        let readLink = readLink
        let identityOf = identityOf
        var copy = self
        copy.readLink = { path in lookups.link(path, readLink) }
        copy.identityOf = { path in lookups.identity(path, identityOf) }
        return copy
    }

    /// True when `path` or a folder on its way is a protected folder by identity (device and inode),
    /// whatever its spelling: the disk matches `Documentſ` to Documents, and
    /// `/System/Volumes/Data/Users/…` is the home folder by another path. Only `lstat`, which raises
    /// no privacy prompt (protected-folders.json: a stat does not, opening does); the walk stops at
    /// the first protected folder. A path through a link into one lstats below it and still opens
    /// nothing: callers check the resolved path again before they read.
    public func reachesProtectedFolder(_ path: String) -> Bool {
        let guarded = Set((homes.flatMap { home in ProtectedFolderEntry.inHome.map { home + "/" + $0.path } }
            + ProtectedFolderEntry.roots.map(\.path)).compactMap(identityOf))
        guard !guarded.isEmpty else { return false }
        var prefix = ""
        for part in path.split(separator: "/") where part != "." {
            prefix += "/" + part
            if let identity = identityOf(prefix), guarded.contains(identity) { return true }
        }
        return false
    }

    private struct Identity: Hashable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    /// The links and identities one ``batch()`` read, by path. A lookup holds the lock while it
    /// reads, so threads sharing a batch never read the same path twice. Past `limit` paths a
    /// lookup reads without remembering, so a batch over a huge folder stays bounded.
    private final class BatchLookups: Sendable {
        static let limit = 4096
        private let links = Mutex<[String: String?]>([:])
        private let identities = Mutex<[String: Identity?]>([:])

        func link(_ path: String, _ read: (String) -> String?) -> String? {
            links.withLock { known in
                if let found = known[path] { return found }
                let found = read(path)
                if known.count < Self.limit { known[path] = found }
                return found
            }
        }

        func identity(_ path: String, _ read: (String) -> Identity?) -> Identity? {
            identities.withLock { known in
                if let found = known[path] { return found }
                let found = read(path)
                if known.count < Self.limit { known[path] = found }
                return found
            }
        }
    }

    private static func identity(_ path: String) -> Identity? {
        var info = stat()
        guard blockingLstat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func guarded(_ path: String, final: Bool) -> String? {
        let folded = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homes = homes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if final && folded.isEmpty {
            return SettingsText.keyed("settings.chats.root.system", "The root folder cannot be a chat folder.").text
        }
        if final && homes.contains(folded) {
            return SettingsText.keyed("settings.chats.root.home", "Choose a harness data folder, not your home folder.").text
        }
        func under(_ root: String) -> Bool { folded == root || folded.hasPrefix(root + "/") }
        // The one protected-folder list: cmux-tui/crates/acpmux/data/protected-folders.json.
        let volumes = ProtectedFolderEntry.roots.map { $0.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if volumes.contains(where: under) {
            return SettingsText.keyed("settings.chats.root.volume", "Folders on other or network volumes are not allowed.").text
        }
        let guarded = ProtectedFolderEntry.inHome.map(\.path)
        if homes.contains(where: { home in guarded.contains { under(home + "/" + $0.lowercased()) } }) {
            return SettingsText.keyed("settings.chats.root.protected", "This folder is protected by macOS privacy controls.").text
        }
        return nil
    }

    /// Only resolves the home path itself, never a child of a protected folder.
    private static func resolveHome(_ home: String, readLink: (String) -> String?) -> String {
        var parts = home.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !parts.isEmpty {
            let part = parts.removeFirst()
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let target = readLink(candidate) {
                links += 1
                guard links <= 40 else { return home }
                if target.hasPrefix("/") { resolved = [] }
                parts = target.split(separator: "/").map(String.init) + parts
            } else { resolved.append(part) }
        }
        return "/" + resolved.joined(separator: "/")
    }

}

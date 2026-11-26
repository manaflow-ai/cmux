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
        let resolved = Self.walk("chat_roots.resolve_home", ["home": .string(home)], readLink: readLink)["home"]?.stringValue
        homes = [home, resolved ?? home]
    }

    /// A localized refusal, or nil for an absolute, unprotected path. Rust walks the path (cmux-config
    /// app_ops/effective.rs, `chat_roots.refusal`): the spelling first, since resolving a protected
    /// descendant would read it, then each folder on the way, asking this validator's `readLink` for
    /// each folder it reaches.
    public func refusal(_ path: String) -> String? {
        let reply = Self.walk("chat_roots.refusal", ["path": .string(path), "homes": .array(homes.map(JSONValue.string))], readLink: readLink)
        switch reply["refusal"]?.stringValue {
        case "relative": return SettingsText.keyed("settings.chats.root.relative", "Use an absolute folder path.").text
        case "symlink": return SettingsText.keyed("settings.chats.root.symlink", "This folder has too many symbolic links.").text
        case "system": return SettingsText.keyed("settings.chats.root.system", "The root folder cannot be a chat folder.").text
        case "home": return SettingsText.keyed("settings.chats.root.home", "Choose a harness data folder, not your home folder.").text
        case "volume": return SettingsText.keyed("settings.chats.root.volume", "Folders on other or network volumes are not allowed.").text
        case "protected": return SettingsText.keyed("settings.chats.root.protected", "This folder is protected by macOS privacy controls.").text
        default: return nil
        }
    }

    /// Runs a `chat_roots` op, answering each folder it asks about (`need`) with `readLink`, once.
    private static func walk(_ op: String, _ request: [String: JSONValue], readLink: (String) -> String?) -> JSONValue {
        var request = request
        var links: [String: JSONValue] = [:]
        request["links"] = .object(links)
        var reply = SettingsRust.answer(op, .object(request))
        // Each turn answers a folder not yet asked about, so the walk ends.
        while let need = reply["need"]?.stringValue, links[need] == nil {
            links[need] = readLink(need).map(JSONValue.string) ?? .null
            request["links"] = .object(links)
            reply = SettingsRust.answer(op, .object(request))
        }
        return reply
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
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

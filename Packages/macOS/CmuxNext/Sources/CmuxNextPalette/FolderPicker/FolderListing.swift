public import Foundation
import CmuxNextCompat

/// One entry of a listed folder.
public nonisolated struct FolderEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    /// A folder with a `.git` inside (a repository or a worktree).
    public let isGitRepository: Bool

    public init(name: String, isDirectory: Bool, isGitRepository: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isGitRepository = isGitRepository
    }

    /// Dot entries show only for a query that starts with `.`.
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// Why a folder has no listing; the picker shows it as a row.
public nonisolated enum FolderListingFailure: Equatable, Sendable {
    case permissionDenied
    case notFound
    case notAFolder
    case other(Int32)
}

/// One level of a folder, read off the main actor: folders first, then
/// the files the mode lists, each by name in Finder order. Bounded: at
/// most `scanLimit` names are read from a huge folder, and `limit` of each
/// kind (visible, hidden) are listed; the rest is a count ("Show more").
public nonisolated struct FolderListing: Equatable, Sendable {
    public var entries: [FolderEntry]
    /// Entries the mode lists beyond `entries` (paging), plus any not read.
    public var remaining: Int
    /// The folder has more names than were read (`scanLimit`).
    public var stoppedEarly: Bool
    public var failure: FolderListingFailure?

    public init(entries: [FolderEntry], remaining: Int = 0, stoppedEarly: Bool = false, failure: FolderListingFailure? = nil) {
        self.entries = entries
        self.remaining = remaining
        self.stoppedEarly = stoppedEarly
        self.failure = failure
    }

    public static let scanLimit = 200_000

    /// Lists `directory` for `mode`. Blocking file system work: call it off
    /// the main actor (``read(_:mode:limit:)``).
    public static func readNow(_ directory: URL, mode: PickerMode, limit: Int, scanLimit: Int = Self.scanLimit) -> FolderListing {
        let path = directory.path
        let base = path == "/" ? "" : path
        // SAFETY: opendir reads the NUL-terminated copy of the path made for the call; `handle` is this call's own
        // directory stream, closed once on return. Each record readdir returns is valid until the next readdir or
        // closedir on it, and record(_:) copies the name and type out before the loop asks for the next one.
        guard let handle = unsafe opendir(path) else { return FolderListing(entries: [], failure: failure(errno)) }
        defer { unsafe closedir(handle) }
        var folders: [String] = [], files: [String] = []
        var scanned = 0, stoppedEarly = false
        // One type check per extension, not per file.
        var verdicts: [String: Bool] = [:]
        func lists(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            if let known = verdicts[ext] { return known }
            let verdict = mode.lists(file: name)
            verdicts[ext] = verdict
            return verdict
        }
        // SAFETY: `handle` is the open stream above; each record is copied out (record(_:)) before the next readdir.
        while let entry = unsafe readdir(handle) {
            let (name, type) = unsafe record(entry)
            if name == "." || name == ".." { continue }
            scanned += 1
            if scanned > scanLimit {
                stoppedEarly = true
                break
            }
            switch isFolder(type: type, at: base + "/" + name) {
            case true: folders.append(name)
            case false where lists(name): files.append(name)
            default: break
            }
        }
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        folders.sort(by: order)
        files.sort(by: order)
        var entries: [FolderEntry] = []
        var remaining = 0
        // Visible entries first; hidden ones get their own page, so a
        // folder of dot files never pushes the visible ones out.
        for hidden in [false, true] {
            let kind = folders.filter { $0.hasPrefix(".") == hidden }.map { ($0, true) }
                + files.filter { $0.hasPrefix(".") == hidden }.map { ($0, false) }
            remaining += max(0, kind.count - limit)
            for (name, isDirectory) in kind.prefix(limit) {
                // A guarded folder (Documents, Library, ...) is not looked
                // into until the user opens it: a probe could raise a prompt.
                let child = base + "/" + name
                // SAFETY: access reads the NUL-terminated copy of the path made for the call.
                let git = unsafe isDirectory && PickerPrivacy.mayProbe(child) && blockingAccess(child + "/.git", F_OK) == 0
                entries.append(FolderEntry(name: name, isDirectory: isDirectory, isGitRepository: git))
            }
        }
        return FolderListing(entries: entries, remaining: remaining, stoppedEarly: stoppedEarly)
    }

    /// ``readNow(_:mode:limit:scanLimit:)`` on a background thread.
    public static func read(_ directory: URL, mode: PickerMode, limit: Int) async -> FolderListing {
        await Task.detached(priority: .userInitiated) {
            readNow(directory, mode: mode, limit: limit)
        }.value
    }

    /// The name and type of one `readdir` record. A record is `d_reclen`
    /// bytes long, not `sizeof(dirent)`: the last one in the buffer may end
    /// just before an unmapped page. So only the record's own bytes are
    /// read (the fields at their offsets, the name by `d_namlen`), never
    /// the whole struct or its 1024-byte `d_name`.
    static func record(_ entry: UnsafeMutablePointer<dirent>) -> (name: String, type: UInt8) {
        // SAFETY: `entry` is a record readdir returned and has not yet reused (the caller's loop); d_namlen and
        // d_type lie inside the record's fixed head, and its d_namlen name bytes start at d_name and end inside
        // the record's d_reclen bytes. Only those bytes are read, by unaligned loads and one copy into a String.
        let raw = unsafe UnsafeRawPointer(entry)
        let length = unsafe Int(raw.loadUnaligned(fromByteOffset: Self.nameLengthOffset, as: UInt16.self))
        let type = unsafe raw.loadUnaligned(fromByteOffset: Self.typeOffset, as: UInt8.self)
        let bytes = unsafe UnsafeRawBufferPointer(start: raw + Self.nameOffset, count: length)
        return (unsafe String(decoding: bytes, as: UTF8.self), type)
    }

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) ?? 21
    private static let nameLengthOffset = MemoryLayout<dirent>.offset(of: \dirent.d_namlen) ?? 18
    private static let typeOffset = MemoryLayout<dirent>.offset(of: \dirent.d_type) ?? 20

    /// A folder, or a link to one (links and unknown types need a stat).
    private static func isFolder(type: UInt8, at path: String) -> Bool {
        switch Int32(type) {
        case DT_DIR: return true
        case DT_LNK, DT_UNKNOWN:
            var info = stat()
            // SAFETY: stat reads the NUL-terminated copy of the path made for the call and writes one struct stat
            // into `info`, a local live for the call.
            return unsafe blockingStat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        default: return false
        }
    }

    private static func failure(_ code: Int32) -> FolderListingFailure {
        switch code {
        case EACCES, EPERM: .permissionDenied
        case ENOENT: .notFound
        case ENOTDIR: .notAFolder
        default: .other(code)
        }
    }
}

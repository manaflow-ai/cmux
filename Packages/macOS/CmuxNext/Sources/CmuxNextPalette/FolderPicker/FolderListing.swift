public import Foundation

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
        guard let handle = opendir(path) else { return FolderListing(entries: [], failure: failure(errno)) }
        defer { closedir(handle) }
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
        while let entry = readdir(handle) {
            let (name, type) = record(entry)
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
                let git = isDirectory && PickerPrivacy.mayProbe(child) && access(child + "/.git", F_OK) == 0
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
        let raw = UnsafeRawPointer(entry)
        let length = Int(raw.loadUnaligned(fromByteOffset: Self.nameLengthOffset, as: UInt16.self))
        let type = raw.loadUnaligned(fromByteOffset: Self.typeOffset, as: UInt8.self)
        let bytes = UnsafeRawBufferPointer(start: raw + Self.nameOffset, count: length)
        return (String(decoding: bytes, as: UTF8.self), type)
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
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
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

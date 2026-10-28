import Darwin
public import Foundation
public import Security

/// Code signature checks on disk (`SecStaticCodeCheckValidity`), each made once per version of the code.
///
/// A strict check reads and hashes every page of the code (a framework or a helper app with nested code
/// takes hundreds of milliseconds), and the same items are checked again and again: the bundled acpmux at
/// each environment resolve, the Computer Use helper candidates at each setup read, the kept builds at each
/// rollback read. A result is kept for the code's version (``CodeVersion``) and used again only while that
/// version is unchanged; a version that changed while the check ran is not kept.
///
/// Every call blocks (`stat` calls, and the check on a miss): run it on a lane, never on the main thread.
public final class StaticCodeValidityCache: Sendable {
    /// The process's cache: a signature on disk is the same for every caller.
    public static let process = StaticCodeValidityCache()

    /// Results kept at most; past it the cache starts again (a process checks a few dozen items).
    static let capacity = 256

    private struct Key: Hashable {
        var path: String
        var flags: UInt32
        var requirement: String?
    }

    private struct Entry {
        var version: CodeVersion
        var valid: Bool
    }

    private let entries = Mutex<[Key: Entry]>([:])
    private let check: @Sendable (URL, SecCSFlags, String?) -> Bool

    /// A cache over `check` (tests count its calls); the default is ``checkValidity(_:flags:requirement:fileID:line:)``.
    public init(check: @escaping @Sendable (URL, SecCSFlags, String?) -> Bool = { StaticCodeValidityCache.checkValidity($0, flags: $1, requirement: $2) }) {
        self.check = check
    }

    /// Whether the code at `url` is validly signed under `flags` and satisfies `requirement` (requirement
    /// language text, nil for none). Missing code is not valid, and that answer is not kept.
    public func isValid(_ url: URL, flags: SecCSFlags, requirement: String?, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        guard let before = CodeVersion(url, fileID: fileID, line: line) else { return false }
        let key = Key(path: url.path, flags: flags.rawValue, requirement: requirement)
        if let entry = entries.withLock({ $0[key] }), entry.version == before { return entry.valid }
        let valid = check(url, flags, requirement)
        guard CodeVersion(url, fileID: fileID, line: line) == before else { return valid }
        entries.withLock { entries in
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = Entry(version: before, valid: valid)
        }
        return valid
    }

    /// The uncached check through the checked seam: false when the code or the requirement cannot be made.
    public static func checkValidity(_ url: URL, flags: SecCSFlags, requirement: String?,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var compiled: SecRequirement?
        if let requirement {
            guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, compiled != nil else { return false }
        }
        return blockingSecStaticCodeCheckValidity(code, flags, compiled, fileID: fileID, line: line) == errSecSuccess
    }
}

/// The version of code on disk a kept check result belongs to: the device, inode, mode, size, modification and
/// status-change times of the item and, for a bundle, of every entry under it. A strict check of a bundle hashes
/// every file its seal lists and every nested code item (`kSecCSCheckNestedCode`), so every file is part of the
/// version: a re-sign rewrites the seal; a replace by rename makes a new inode; an in-place write moves that
/// file's status-change time, which no process can set back; an added or removed file changes the entry list.
/// Entries are read with `lstat`, so a symbolic link is stamped as a link and never followed out of the bundle.
struct CodeVersion: Equatable {
    private var stamps: [String: FileStamp]

    init?(_ url: URL, fileID: StaticString, line: UInt) {
        guard let item = FileStamp(url.path, fileID: fileID, line: line) else { return nil }
        stamps = ["": item]
        guard item.isDirectory else { return }
        let entries = (try? FileManager.checked.subpathsOfDirectory(atPath: url.path, fileID: fileID, line: line)) ?? []
        for entry in entries {
            stamps[entry] = FileStamp(url.appending(path: entry).path, link: true, fileID: fileID, line: line)
        }
    }
}

/// One `stat` of a file: what changes when the file is replaced, rewritten or touched.
private struct FileStamp: Equatable {
    var device: Int32
    var inode: UInt64
    var mode: UInt16
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanos: Int
    var changedSeconds: Int
    var changedNanos: Int

    var isDirectory: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) }

    /// `link`: stamp a symbolic link itself (`lstat`), not what it points to.
    init?(_ path: String, link: Bool = false, fileID: StaticString, line: UInt) {
        var info = stat()
        let status = link ? blockingLstat(path, &info, fileID: fileID, line: line) : blockingStat(path, &info, fileID: fileID, line: line)
        guard status == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        mode = info.st_mode
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
    }
}

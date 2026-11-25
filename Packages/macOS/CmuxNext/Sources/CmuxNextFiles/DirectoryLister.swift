public import Foundation
import UniformTypeIdentifiers

/// Lists one folder's children: the seam the Files model reads through.
///
/// Tests pass a fake that returns fixed entries; the app uses
/// ``DirectoryLister``.
public protocol DirectoryListing: Sendable {
    /// Every child of `folder` (hidden ones included; the model filters).
    /// - Throws: ``FileBrowserError/unreadable(_:_:)`` when the folder cannot be opened.
    func list(_ folder: URL) async throws -> [FileEntry]

    /// The current entry for one item, or nil when it no longer exists
    /// (for live updates of single paths).
    func entry(at url: URL) async -> FileEntry?
}

/// Lists folders with `getattrlistbulk(2)`: name, type, dates, flags and size
/// for up to a few thousand items per system call, off the main actor.
///
/// Measured on 100 000 files: ~230 ms with `FileManager` plus resource keys,
/// against ~56 s for Finder's own `name of every item` (PARITY.md).
public struct DirectoryLister: DirectoryListing {
    /// Makes a lister. It holds no state.
    public init() {}

    @concurrent
    public func list(_ folder: URL) async throws -> [FileEntry] {
        try Self.listSync(folder)
    }

    @concurrent
    public func entry(at url: URL) async -> FileEntry? {
        Self.entrySync(at: url)
    }

    /// The synchronous listing (also used by benchmarks).
    public static func listSync(_ folder: URL) throws -> [FileEntry] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw FileBrowserError.unreadable(folder, errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(bitPattern: ATTR_CMN_NAME) | attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE)
            | attrgroup_t(bitPattern: ATTR_CMN_CRTIME) | attrgroup_t(bitPattern: ATTR_CMN_MODTIME)
            | attrgroup_t(bitPattern: ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH)

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [FileEntry] = []
        var packageCache: [String: Bool] = [:]
        // wakeup-allow: each pass blocks in getattrlistbulk for the next batch; 0 (the end) or an error ends it
        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count < 0 { throw FileBrowserError.unreadable(folder, errno) }
            if count == 0 { break }
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if let entry = parse(record, in: folder, packages: &packageCache) { entries.append(entry) }
                record += length
            }
        }
        return entries
    }

    /// One item through `lstat`, or nil when it is gone.
    public static func entrySync(at url: URL) -> FileEntry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let kind: FileKind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = isPackage(url.lastPathComponent) ? .package : .folder
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let hidden = url.lastPathComponent.hasPrefix(".") || (info.st_flags & UInt32(UF_HIDDEN)) != 0
        return FileEntry(url: url, kind: kind, size: kind == .file ? Int64(info.st_size) : 0,
                         modified: date(info.st_mtimespec), created: date(info.st_birthtimespec), isHidden: hidden)
    }

    private static func parse(_ record: UnsafeRawPointer, in folder: URL, packages: inout [String: Bool]) -> FileEntry? {
        var cursor = record + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        guard common & attrgroup_t(bitPattern: ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (cursor + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        cursor += MemoryLayout<attrreference_t>.size

        var type: fsobj_type_t = 0
        if common & attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE) != 0 {
            type = cursor.loadUnaligned(as: fsobj_type_t.self)
            cursor += MemoryLayout<fsobj_type_t>.size
        }
        var created = timespec()
        if common & attrgroup_t(bitPattern: ATTR_CMN_CRTIME) != 0 {
            created = cursor.loadUnaligned(as: timespec.self)
            cursor += MemoryLayout<timespec>.size
        }
        var modified = timespec()
        if common & attrgroup_t(bitPattern: ATTR_CMN_MODTIME) != 0 {
            modified = cursor.loadUnaligned(as: timespec.self)
            cursor += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(bitPattern: ATTR_CMN_FLAGS) != 0 {
            flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH) != 0 {
            size = cursor.loadUnaligned(as: off_t.self)
        }

        let kind: FileKind
        switch type {
        case fsobj_type_t(VDIR.rawValue):
            let ext = (name as NSString).pathExtension
            if ext.isEmpty {
                kind = .folder
            } else if let cached = packages[ext] {
                kind = cached ? .package : .folder
            } else {
                let package = isPackage(name)
                packages[ext] = package
                kind = package ? .package : .folder
            }
        case fsobj_type_t(VREG.rawValue): kind = .file
        case fsobj_type_t(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }
        let hidden = name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
        return FileEntry(name: name, in: folder, kind: kind, size: kind == .file ? size : 0,
                         modified: date(modified), created: date(created), isHidden: hidden)
    }

    /// True for a folder name Finder shows as one item (by its extension's type).
    public static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        // Ask for a folder type: the plain lookup assumes data and can miss
        // bundle types such as `.app` on hosts where LaunchServices is cold.
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

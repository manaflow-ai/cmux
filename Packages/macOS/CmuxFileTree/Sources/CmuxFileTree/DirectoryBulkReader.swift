import Darwin
import Foundation

/// Reads a local directory with `getattrlistbulk(2)`.
///
/// One syscall returns names, types, sizes, times and flags for a buffer of
/// entries. The previous `contentsOfDirectory` plus one `fileExists` per entry
/// paid a `stat` per row; for a 50,000-entry `node_modules` that was the
/// difference between roughly 700 ms and a few tens of milliseconds.
struct DirectoryBulkReader: Sendable {
    /// The per-call attribute buffer. Large enough for about 2,000 entries.
    private let bufferSize: Int

    /// Creates a reader.
    /// - Parameter bufferSize: The attribute buffer size in bytes.
    init(bufferSize: Int = 256 * 1024) {
        self.bufferSize = bufferSize
    }

    /// Lists `path`, hidden entries included.
    /// - Parameter path: An absolute directory path.
    /// - Returns: The entries in filesystem order.
    /// - Throws: `POSIXError` when the directory cannot be opened or read.
    func entries(atPath path: String) throws -> [FileTreeEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError(errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) |
            attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME) |
            attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        let parentPrefix = path.hasSuffix("/") ? path : path + "/"
        var result: [FileTreeEntry] = []
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw Self.posixError(code)
            }
            if count == 0 { break }
            var cursor = buffer
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = Self.parseEntry(at: cursor, parentPrefix: parentPrefix) {
                    result.append(entry)
                }
                cursor = cursor.advanced(by: length)
            }
        }
        return result
    }

    private static func parseEntry(at start: UnsafeMutableRawPointer, parentPrefix: String) -> FileTreeEntry? {
        var field = start.advanced(by: MemoryLayout<UInt32>.size)
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

        // Layout per getattrlistbulk(2): the error code precedes the name.
        var entryError: UInt32 = 0
        if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR) != 0 {
            entryError = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: MemoryLayout<UInt32>.size)
        }
        guard returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME) != 0 else { return nil }
        let nameReference = field.loadUnaligned(as: attrreference_t.self)
        let namePointer = field.advanced(by: Int(nameReference.attr_dataoffset))
            .assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePointer)
        field = field.advanced(by: MemoryLayout<attrreference_t>.size)
        guard name != ".", name != ".." else { return nil }
        let path = parentPrefix + name
        if entryError != 0 {
            return FileTreeEntry(name: name, path: path, kind: .other)
        }

        var objectType = UInt32(VNON.rawValue)
        if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE) != 0 {
            objectType = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: MemoryLayout<UInt32>.size)
        }
        var modificationTime: TimeInterval?
        if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME) != 0 {
            let time = field.loadUnaligned(as: timespec.self)
            modificationTime = TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
            field = field.advanced(by: MemoryLayout<timespec>.size)
        }
        var flags: UInt32 = 0
        if returned.commonattr & attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: MemoryLayout<UInt32>.size)
        }
        var size: Int64?
        if returned.fileattr & attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH) != 0 {
            size = field.loadUnaligned(as: off_t.self)
        }

        let kind: FileTreeEntryKind
        switch objectType {
        case UInt32(VDIR.rawValue):
            kind = .directory
        case UInt32(VREG.rawValue):
            kind = .file
        case UInt32(VLNK.rawValue):
            kind = Self.symbolicLinkKind(path: path)
        default:
            kind = .other
        }
        return FileTreeEntry(
            name: name,
            path: path,
            kind: kind,
            size: kind == .file ? size : nil,
            modificationTime: modificationTime,
            hasHiddenFlag: flags & UInt32(UF_HIDDEN) != 0
        )
    }

    /// Follows one symlink to decide whether it expands like a folder.
    private static func symbolicLinkKind(path: String) -> FileTreeEntryKind {
        var info = stat()
        guard stat(path, &info) == 0 else { return .symbolicLink }
        return (info.st_mode & S_IFMT) == S_IFDIR ? .symbolicLinkToDirectory : .symbolicLink
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

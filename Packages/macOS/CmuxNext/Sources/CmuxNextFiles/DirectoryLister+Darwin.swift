#if canImport(Darwin)
public import Foundation

/// The macOS listing: `getattrlistbulk(2)` reads name, type, dates, flags and size for up to a few
/// thousand items per system call.
extension DirectoryLister {
    /// The synchronous listing (also used by benchmarks).
    public static func listSync(_ folder: URL) throws -> [FileEntry] {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let fd = unsafe open(folder.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw FileBrowserError.unreadable(folder, errno) }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(bitPattern: ATTR_CMN_NAME) | attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE)
            | attrgroup_t(bitPattern: ATTR_CMN_CRTIME) | attrgroup_t(bitPattern: ATTR_CMN_MODTIME)
            | attrgroup_t(bitPattern: ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH)

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var entries: [FileEntry] = []
        var packageCache: [String: Bool] = [:]
        // wakeup-allow: bounded: each pass blocks in getattrlistbulk for the next batch; 0 (the end) or an error ends it
        while true {
            // SAFETY: getattrlistbulk reads `request`, a local, and writes at most bytes.count bytes into the array's
            // own storage, lent for the call; nothing keeps the pointer after it.
            let count = unsafe buffer.withUnsafeMutableBytes { bytes in
                unsafe getattrlistbulk(fd, &request, bytes.baseAddress, bytes.count, 0)
            }
            if count < 0 { throw FileBrowserError.unreadable(folder, errno) }
            if count == 0 { break }
            parseBatch(buffer, count: Int(count), in: folder, packages: &packageCache, into: &entries)
        }
        return entries
    }

    /// The entries of one `getattrlistbulk` batch: `count` records, one after another from the start of
    /// `bytes`. A record whose length field is short or runs past the buffer ends the batch; one whose
    /// attributes run past its own length is skipped.
    static func parseBatch(_ bytes: [UInt8], count: Int, in folder: URL, packages: inout [String: Bool],
                           into entries: inout [FileEntry]) {
        var start = 0
        for _ in 0..<count {
            guard let record = AttributeRecordReader(bytes, at: start) else { return }
            if let entry = parse(record, in: folder, packages: &packages) { entries.append(entry) }
            start += record.length
        }
    }

    /// One item through `lstat`, or nil when it is gone.
    public static func entrySync(at url: URL) -> FileEntry? {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local live for the call.
        guard unsafe lstat(url.path, &info) == 0 else { return nil }
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

    /// One record, in getattrlist(2)'s order: the length, the returned attribute_set_t, then each returned
    /// attribute (name, type, creation and modification times, flags, then the data length). Nil when the
    /// record has no name or an attribute runs past its end.
    static func parse(_ record: AttributeRecordReader, in folder: URL, packages: inout [String: Bool]) -> FileEntry? {
        var reader = record
        // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr.
        guard let common = reader.read(attrgroup_t.self), reader.skip(8),
              let fileAttributes = reader.read(attrgroup_t.self), reader.skip(4) else { return nil }

        guard common & attrgroup_t(bitPattern: ATTR_CMN_NAME) != 0 else { return nil }
        // attrreference_t: the name's offset from the reference itself, then its length with the NUL.
        let reference = reader.position
        guard let nameOffset = reader.read(UInt32.self), let nameLength = reader.read(UInt32.self),
              let name = reader.text(at: reference + Int(Int32(bitPattern: nameOffset)), length: Int(nameLength))
        else { return nil }

        var type: fsobj_type_t = 0
        if common & attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE) != 0 {
            guard let value = reader.read(fsobj_type_t.self) else { return nil }
            type = value
        }
        var created = timespec()
        if common & attrgroup_t(bitPattern: ATTR_CMN_CRTIME) != 0 {
            guard let value = reader.readTime() else { return nil }
            created = value
        }
        var modified = timespec()
        if common & attrgroup_t(bitPattern: ATTR_CMN_MODTIME) != 0 {
            guard let value = reader.readTime() else { return nil }
            modified = value
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(bitPattern: ATTR_CMN_FLAGS) != 0 {
            guard let value = reader.read(UInt32.self) else { return nil }
            flags = value
        }
        var size: Int64 = 0
        if fileAttributes & attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH) != 0 {
            guard let value = reader.read(UInt64.self) else { return nil }
            size = Int64(bitPattern: value)
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
}
#endif

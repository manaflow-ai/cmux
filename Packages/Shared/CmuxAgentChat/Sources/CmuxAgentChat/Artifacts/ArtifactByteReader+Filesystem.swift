import Darwin
import Foundation
import UniformTypeIdentifiers

extension ArtifactByteReader {
    static let utf8SniffByteCount = 8 * 1024

    struct VerifiedMetadata {
        let fileType: mode_t
        let size: Int64
        let modifiedAt: Date
        let device: UInt64
        let inode: UInt64
    }

    func kind(
        path: String,
        isDirectory: Bool,
        isRegularFile: Bool?
    ) -> ChatArtifactKind {
        if isDirectory { return .directory }
        if isRegularFile == false { return .binary }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard let type, !type.isDynamic else {
            let verifiedRegularFile: Bool
            if let isRegularFile {
                verifiedRegularFile = isRegularFile
            } else {
                verifiedRegularFile = (try? lstatMetadata(path: path).fileType == S_IFREG) ?? false
            }
            guard verifiedRegularFile else { return .binary }
            return isUTF8Text(path: path) ? .text : .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    func isUTF8Text(path: String) -> Bool {
        guard let opened = try? openVerifiedRegularFile(path: path) else {
            return false
        }
        let handle = opened.handle
        defer { try? handle.close() }
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: Self.utf8SniffByteCount + 1) ?? Data()
        } catch {
            return false
        }
        let sample = Data(bytes.prefix(Self.utf8SniffByteCount))
        if String(data: sample, encoding: .utf8) != nil {
            return true
        }
        guard bytes.count > Self.utf8SniffByteCount else {
            return false
        }
        return hasValidUTF8PrefixEndingInPartialScalar(sample)
    }

    func isUTF8Text(descriptor: Int32) -> Bool {
        let limit = Self.utf8SniffByteCount
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            var total = 0
            while total < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total,
                    off_t(total)
                )
                if result < 0 {
                    if Darwin.errno == EINTR { continue }
                    return nil
                }
                if result == 0 { break }
                total += result
            }
            return total
        }
        guard let count else { return false }
        let sample = Data(bytes.prefix(min(count, limit)))
        if String(data: sample, encoding: .utf8) != nil { return true }
        guard count > limit else { return false }
        return hasValidUTF8PrefixEndingInPartialScalar(sample)
    }

    func hasValidUTF8PrefixEndingInPartialScalar(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        let earliestCandidate = max(0, bytes.count - 4)
        for start in stride(from: bytes.count - 1, through: earliestCandidate, by: -1) {
            guard let expectedLength = utf8ScalarLength(leadingByte: bytes[start]) else {
                continue
            }
            let actualLength = bytes.count - start
            guard actualLength < expectedLength,
                  utf8PartialScalarBytesAreValid(Array(bytes[start...])) else {
                continue
            }
            let prefix = Data(bytes[..<start])
            return String(data: prefix, encoding: .utf8) != nil
        }
        return false
    }

    /// Opens `path` without blocking and validates the opened descriptor as a regular file.
    func openVerifiedRegularFile(
        path: String,
        expectedCanonicalPath: String? = nil,
        expectedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> (handle: FileHandle, size: Int64) {
        // Resolve aliases before opening so the descriptor check below compares
        // against the path the caller authorized, not a path that a concurrent
        // parent-directory swap could make `path` resolve to afterward.
        let expectedCanonicalPath = expectedCanonicalPath ?? canonicalPath(path)
        // Set close-on-exec atomically at open; fcntl afterward cannot close the fork race.
        // `O_NOFOLLOW` rejects a replaced leaf; the canonical descriptor check
        // below rejects a parent-directory redirect while retaining support for
        // system aliases such as `/var` -> `/private/var`.
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw filesystemError(errno: Darwin.errno) }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let errorCode = Darwin.errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw Error.notRegularFile
        }
        if let expectedIdentity,
           ChatArtifactFileIdentity(
               device: UInt64(metadata.st_dev),
               inode: UInt64(metadata.st_ino)
           ) != expectedIdentity {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        guard descriptorMatchesPath(descriptor, expectedCanonicalPath: expectedCanonicalPath) else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            let errorCode = Darwin.errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }

        return (
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            max(Int64(metadata.st_size), 0)
        )
    }

    /// Reads metadata through a pinned parent directory without opening the
    /// target entry, so sockets, devices, and FIFOs remain side-effect free.
    func verifiedMetadata(
        path: String,
        expectedCanonicalPath: String? = nil,
        expectedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> VerifiedMetadata {
        let expectedCanonicalPath = expectedCanonicalPath ?? canonicalPath(path)
        if expectedCanonicalPath == "/" {
            let descriptor = try openVerifiedDirectory(
                path: path,
                expectedCanonicalPath: expectedCanonicalPath,
                expectedIdentity: expectedIdentity
            )
            defer { Darwin.close(descriptor) }
            return try metadata(from: descriptor)
        }
        let expectedURL = URL(fileURLWithPath: expectedCanonicalPath)
        let expectedParentPath = expectedURL.deletingLastPathComponent().path
        let parentPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        let parentDescriptor = try openVerifiedParentDirectory(
            path: parentPath,
            expectedCanonicalPath: expectedParentPath
        )
        defer { Darwin.close(parentDescriptor) }
        let leafName = expectedURL.lastPathComponent
        var metadata = Darwin.stat()
        let result = leafName.withCString { pointer in
            Darwin.fstatat(parentDescriptor, pointer, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw filesystemError(errno: errno)
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw Error.fileNotFound
        }
        if let expectedIdentity,
           ChatArtifactFileIdentity(
               device: UInt64(metadata.st_dev),
               inode: UInt64(metadata.st_ino)
           ) != expectedIdentity {
            throw Error.fileNotFound
        }
        return VerifiedMetadata(
            fileType: metadata.st_mode & S_IFMT,
            size: max(Int64(metadata.st_size), 0),
            modifiedAt: Date(
                timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
                    + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    func openVerifiedRegularFileAt(
        path: String,
        expectedCanonicalPath: String,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) throws -> (descriptor: Int32, size: Int64) {
        let expectedURL = URL(fileURLWithPath: expectedCanonicalPath)
        let parentPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        let parentDescriptor = try openVerifiedParentDirectory(
            path: parentPath,
            expectedCanonicalPath: expectedURL.deletingLastPathComponent().path
        )
        defer { Darwin.close(parentDescriptor) }
        let leafName = expectedURL.lastPathComponent
        let descriptor = leafName.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { throw filesystemError(errno: errno) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let errorCode = errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              UInt64(metadata.st_dev) == expectedDevice,
              UInt64(metadata.st_ino) == expectedInode else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        return (descriptor, max(Int64(metadata.st_size), 0))
    }

    func openVerifiedParentDirectory(
        path: String,
        expectedCanonicalPath: String
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw filesystemError(errno: errno)
        }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let errorCode = errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw Error.notDirectory
        }
        guard descriptorMatchesPath(descriptor, expectedCanonicalPath: expectedCanonicalPath) else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        return descriptor
    }

    func metadata(from descriptor: Int32) throws -> VerifiedMetadata {
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw filesystemError(errno: errno)
        }
        return VerifiedMetadata(
            fileType: metadata.st_mode & S_IFMT,
            size: max(Int64(metadata.st_size), 0),
            modifiedAt: Date(
                timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
                    + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    func extensionDerivedKind(path: String) -> ChatArtifactKind {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard let type, !type.isDynamic else { return .binary }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    func openVerifiedDirectory(
        path: String,
        expectedCanonicalPath: String? = nil,
        expectedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> Int32 {
        let expectedCanonicalPath = expectedCanonicalPath ?? canonicalPath(path)
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw filesystemError(errno: Darwin.errno)
        }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let errorCode = Darwin.errno
            Darwin.close(descriptor)
            throw filesystemError(errno: errorCode)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            throw Error.notDirectory
        }
        if let expectedIdentity,
           ChatArtifactFileIdentity(
               device: UInt64(metadata.st_dev),
               inode: UInt64(metadata.st_ino)
           ) != expectedIdentity {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        guard descriptorMatchesPath(descriptor, expectedCanonicalPath: expectedCanonicalPath) else {
            Darwin.close(descriptor)
            throw Error.fileNotFound
        }
        return descriptor
    }

    /// Counts immediate non-symlink children with one bounded `readdir` pass.
    ///
    /// Directory-entry types are trusted when the filesystem supplies them;
    /// only `DT_UNKNOWN` entries require a no-follow metadata lookup. The
    /// result is capped at the same value as ``ArtifactByteReader.list`` so a
    /// gallery row never performs work proportional to an unbounded folder.
    func countImmediateChildren(path: String) throws -> (count: Int, isCapped: Bool)? {
        let directoryDescriptor = try openVerifiedDirectory(path: path)
        defer { Darwin.close(directoryDescriptor) }

        // Keep the descriptor's close-on-exec bit while handing ownership to
        // `fdopendir`; the original remains available for `fstatat` calls.
        let streamDescriptor = Darwin.fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 3)
        guard streamDescriptor >= 0,
              let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { Darwin.close(streamDescriptor) }
            throw Error.readFailed
        }
        defer { closedir(stream) }

        var count = 0
        var scannedEntryCount = 0

        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let errorCode = errno
                guard errorCode == 0 else {
                    throw filesystemError(errno: Int32(errorCode))
                }
                break
            }
            scannedEntryCount += 1
            if scannedEntryCount > Self.maximumDirectoryScanEntryCount {
                // A non-empty lower bound is useful to the caller, but `0+`
                // is misleading when the scan saw only skipped entries.
                return count == 0
                    ? nil
                    : (count: min(count, Self.maximumDirectoryEntryCount), isCapped: true)
            }
            if scannedEntryCount.isMultiple(of: 512) {
                try Task.checkCancellation()
            }

            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard name != ".", name != ".." else { continue }

            let direntType = Int32(entry.pointee.d_type)
            if direntType == DT_LNK {
                continue
            }
            if direntType == DT_UNKNOWN {
                var metadata = Darwin.stat()
                let metadataResult = name.withCString { pointer in
                    Darwin.fstatat(
                        directoryDescriptor,
                        pointer,
                        &metadata,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard metadataResult == 0,
                      (metadata.st_mode & S_IFMT) != S_IFLNK else {
                    continue
                }
            }

            count += 1
            if count > Self.maximumDirectoryEntryCount {
                return (count: Self.maximumDirectoryEntryCount, isCapped: true)
            }
        }
        return (count: count, isCapped: false)
    }

    func descriptorMatchesPath(
        _ descriptor: Int32,
        expectedCanonicalPath: String
    ) -> Bool {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result == 0 else { return false }
        let openedPath = String(
            decoding: buffer.prefix { $0 != 0 },
            as: UTF8.self
        )
        guard !openedPath.isEmpty else { return false }
        let canonicalOpenedPath = URL(fileURLWithPath: openedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return canonicalOpenedPath == expectedCanonicalPath
    }

    func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    func kindForDescriptor(
        path: String,
        descriptor: Int32,
        isDirectory: Bool
    ) -> ChatArtifactKind {
        if isDirectory { return .directory }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        guard let type, !type.isDynamic else {
            return isUTF8Text(descriptor: descriptor) ? .text : .binary
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) {
            return .text
        }
        return .binary
    }

    func utf8ScalarLength(leadingByte: UInt8) -> Int? {
        switch leadingByte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }

    func utf8PartialScalarBytesAreValid(_ bytes: [UInt8]) -> Bool {
        guard let leadingByte = bytes.first else { return false }
        for byte in bytes.dropFirst() where byte & 0xC0 != 0x80 {
            return false
        }
        guard bytes.count > 1 else { return true }
        let firstContinuation = bytes[1]
        switch leadingByte {
        case 0xE0:
            return firstContinuation >= 0xA0
        case 0xED:
            return firstContinuation <= 0x9F
        case 0xF0:
            return firstContinuation >= 0x90
        case 0xF4:
            return firstContinuation <= 0x8F
        default:
            return true
        }
    }

    func lstatMetadata(path: String) throws -> VerifiedMetadata {
        var metadata = Darwin.stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            throw filesystemError(errno: errno)
        }
        return VerifiedMetadata(
            fileType: metadata.st_mode & S_IFMT,
            size: max(Int64(metadata.st_size), 0),
            modifiedAt: Date(
                timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)
                    + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    func filesystemError(_ error: any Swift.Error) -> Error {
        if let readerError = error as? Error {
            return readerError
        }
        if let posixError = error as? POSIXError {
            return filesystemError(errno: posixError.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return filesystemError(errno: Int32(nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            return filesystemError(underlying)
        }
        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileReadNoSuchFile:
                return .fileNotFound
            case .fileReadNoPermission:
                return .permissionDenied
            default:
                break
            }
        }
        return .readFailed
    }

    func filesystemError(errno errorCode: Int32) -> Error {
        switch POSIXErrorCode(rawValue: errorCode) {
        case .ENOENT, .ESTALE:
            return .fileNotFound
        case .EACCES, .EPERM:
            return .permissionDenied
        case .ENOTDIR:
            return .notDirectory
        case .EISDIR:
            return .notRegularFile
        case .ELOOP:
            return .fileNotFound
        default:
            return .readFailed
        }
    }

    func mimeType(path: String, isDirectory: Bool) -> String? {
        guard !isDirectory,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }
}

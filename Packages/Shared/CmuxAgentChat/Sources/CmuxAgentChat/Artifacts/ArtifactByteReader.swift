import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads already-authorized artifact bytes and metadata from the local filesystem.
///
/// Authorization is intentionally outside this type. Callers must scope-check the
/// requested path before invoking these methods.
public struct ArtifactByteReader: Sendable {
    /// Maximum immediate children returned by one directory-list request.
    public static let maximumDirectoryEntryCount = 500
    /// Maximum directory entries inspected before a listing is marked capped.
    static let maximumDirectoryScanEntryCount = 100_000

    /// Filesystem/decoder failures surfaced by artifact RPC handlers.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The scoped path no longer exists or cannot be statted.
        case fileNotFound
        /// The scoped path exists but cannot be read by cmux.
        case permissionDenied
        /// The operation requires a directory, but the path is not one.
        case notDirectory
        /// The operation requires a regular file, but the path is another filesystem type.
        case notRegularFile
        /// The operation does not apply to this media type.
        case unsupportedMedia
        /// The path has a supported media type, but its bytes cannot be decoded.
        case corruptMedia
        /// A decoded image could not be encoded as a thumbnail.
        case previewFailed
        /// The path exists, but a filesystem operation failed for another reason.
        case readFailed
    }

    /// Creates a byte reader.
    public init() {}

    /// Captures the device/inode identity for an already-authorized path.
    ///
    /// Callers retain the returned value and supply it to later reads so a
    /// replacement inode at the same pathname cannot silently become
    /// authorized. The optional canonical path keeps the capture tied to the
    /// same ancestor-swap check used by fetch and listing operations.
    ///
    /// - Parameters:
    ///   - path: Path to inspect.
    ///   - authorizedCanonicalPath: Canonical path captured by the scope check.
    /// - Returns: Stable device/inode identity for the path.
    public func identity(
        path: String,
        authorizedCanonicalPath: String? = nil
    ) throws -> ChatArtifactFileIdentity {
        let metadata = try verifiedMetadata(
            path: path,
            expectedCanonicalPath: authorizedCanonicalPath
        )
        return ChatArtifactFileIdentity(
            device: metadata.device,
            inode: metadata.inode
        )
    }

    /// Reads metadata for an already-authorized path.
    ///
    /// - Parameters:
    ///   - path: Path to inspect.
    ///   - authorizedCanonicalPath: Canonical path captured at authorization
    ///     time. Supplying it pins metadata to the same scope decision and
    ///     rejects an ancestor replacement before the descriptor is opened.
    ///   - authorizedIdentity: Device/inode captured at authorization time.
    ///     Supplying it rejects a replacement object at the same pathname.
    public func stat(
        path: String,
        authorizedCanonicalPath: String? = nil,
        authorizedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> ChatArtifactStat {
        if let authorizedCanonicalPath {
            let metadata = try verifiedMetadata(
                path: path,
                expectedCanonicalPath: authorizedCanonicalPath,
                expectedIdentity: authorizedIdentity
            )
            let kind: ChatArtifactKind
            switch metadata.fileType {
            case S_IFDIR:
                kind = .directory
            case S_IFREG:
                do {
                    let opened = try openVerifiedRegularFileAt(
                        path: path,
                        expectedCanonicalPath: authorizedCanonicalPath,
                        expectedDevice: metadata.device,
                        expectedInode: metadata.inode
                    )
                    defer { Darwin.close(opened.descriptor) }
                    kind = kindForDescriptor(
                        path: path,
                        descriptor: opened.descriptor,
                        isDirectory: false
                    )
                } catch Error.fileNotFound {
                    throw Error.fileNotFound
                } catch {
                    kind = extensionDerivedKind(path: path)
                }
            default:
                kind = .binary
            }
            return ChatArtifactStat(
                exists: true,
                isDirectory: metadata.fileType == S_IFDIR,
                size: metadata.size,
                modifiedAt: metadata.modifiedAt,
                kind: kind,
                mimeType: mimeType(path: path, isDirectory: metadata.fileType == S_IFDIR)
            )
        }
        if let authorizedIdentity {
            let metadata = try verifiedMetadata(
                path: path,
                expectedIdentity: authorizedIdentity
            )
            return stat(path: path, metadata: metadata)
        }
        return stat(path: path, metadata: try lstatMetadata(path: path))
    }

    /// Reads one clamped byte chunk for an already-authorized file path.
    ///
    /// - Parameters:
    ///   - path: Path to read.
    ///   - offset: Requested byte offset, clamped to the opened file size.
    ///   - length: Maximum number of bytes to return.
    ///   - authorizedCanonicalPath: Canonical path captured at authorization
    ///     time. Supplying it prevents an ancestor replacement between scope
    ///     validation and this open from redirecting the read.
    ///   - authorizedIdentity: Device/inode captured at authorization time.
    public func fetch(
        path: String,
        offset: Int64,
        length: Int,
        authorizedCanonicalPath: String? = nil,
        authorizedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> ChatArtifactChunk {
        let opened = try openVerifiedRegularFile(
            path: path,
            expectedCanonicalPath: authorizedCanonicalPath,
            expectedIdentity: authorizedIdentity
        )
        let handle = opened.handle
        defer { try? handle.close() }
        let totalSize = opened.size
        let clampedOffset = min(max(offset, 0), totalSize)
        let data: Data
        do {
            try handle.seek(toOffset: UInt64(clampedOffset))
            data = try handle.read(upToCount: max(0, length)) ?? Data()
        } catch {
            throw filesystemError(error)
        }
        let endOffset = clampedOffset + Int64(data.count)
        return ChatArtifactChunk(
            data: data,
            offset: clampedOffset,
            totalSize: totalSize,
            eof: endOffset >= totalSize
        )
    }

    private func stat(
        path: String,
        metadata: VerifiedMetadata
    ) -> ChatArtifactStat {
        let isDirectory = metadata.fileType == S_IFDIR
        let kind = kind(
            path: path,
            isDirectory: isDirectory,
            isRegularFile: metadata.fileType == S_IFREG
        )
        return ChatArtifactStat(
            exists: true,
            isDirectory: isDirectory,
            size: metadata.size,
            modifiedAt: metadata.modifiedAt,
            kind: kind,
            mimeType: mimeType(path: path, isDirectory: isDirectory)
        )
    }

    /// Generates a JPEG thumbnail for an already-authorized image path.
    ///
    /// - Parameters:
    ///   - path: Image path to decode.
    ///   - maxDimension: Maximum thumbnail dimension in pixels.
    ///   - authorizedCanonicalPath: Canonical path captured at authorization
    ///     time. Supplying it prevents an ancestor replacement between scope
    ///     validation and this open from redirecting the decoder.
    ///   - authorizedIdentity: Device/inode captured at authorization time.
    public func thumbnail(
        path: String,
        maxDimension: Int,
        authorizedCanonicalPath: String? = nil,
        authorizedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> ChatArtifactThumbnail {
        let opened = try openVerifiedRegularFile(
            path: path,
            expectedCanonicalPath: authorizedCanonicalPath,
            expectedIdentity: authorizedIdentity
        )
        defer { try? opened.handle.close() }
        guard kindForDescriptor(
            path: path,
            descriptor: opened.handle.fileDescriptor,
            isDirectory: false
        ) == .image else {
            throw Error.unsupportedMedia
        }
        // Keep the validated descriptor open for ImageIO. Reopening `path`
        // after authorization would permit a concurrent replacement to point
        // the decoder at an unrelated inode.
        let descriptorURL = URL(
            fileURLWithPath: "/dev/fd/\(opened.handle.fileDescriptor)",
            isDirectory: false
        )
        guard let source = CGImageSourceCreateWithURL(descriptorURL as CFURL, nil) else {
            throw Error.corruptMedia
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Error.corruptMedia
        }
        guard let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw Error.previewFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.previewFailed
        }
        return ChatArtifactThumbnail(
            data: destinationData as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Lists up to ``maximumDirectoryEntryCount`` immediate children for an
    /// already-authorized directory.
    ///
    /// One readdir pass collects child names; per-child filesystem metadata is
    /// read only for the capped entries that the listing actually returns.
    ///
    /// - Parameters:
    ///   - path: Directory path to list.
    ///   - authorizedCanonicalPath: Canonical path captured at authorization
    ///     time. Supplying it prevents an ancestor replacement between scope
    ///     validation and this open from redirecting the listing.
    ///   - authorizedIdentity: Device/inode captured at authorization time.
    public func list(
        path: String,
        authorizedCanonicalPath: String? = nil,
        authorizedIdentity: ChatArtifactFileIdentity? = nil
    ) throws -> ChatArtifactDirectoryListing {
        let directoryDescriptor = try openVerifiedDirectory(
            path: path,
            expectedCanonicalPath: authorizedCanonicalPath,
            expectedIdentity: authorizedIdentity
        )
        defer { Darwin.close(directoryDescriptor) }
        // Preserve close-on-exec on the descriptor handed to `fdopendir`; a
        // plain `dup` clears it during the interval before the stream closes.
        let streamDescriptor = Darwin.fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 3)
        guard streamDescriptor >= 0,
              let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { Darwin.close(streamDescriptor) }
            throw Error.readFailed
        }
        defer { closedir(stream) }

        var names = DirectoryNameMaxHeap(capacity: Self.maximumDirectoryEntryCount)
        var listingIncomplete = false
        var scanLimitReached = false
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
                scanLimitReached = true
                break
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
                // Symlink children are intentionally excluded from the result
                // set; filtering before the bounded heap prevents them from
                // consuming slots that should be available to returnable entries.
                continue
            }
            if direntType == DT_UNKNOWN {
                var childMetadata = Darwin.stat()
                let metadataResult = name.withCString { pointer in
                    Darwin.fstatat(
                        directoryDescriptor,
                        pointer,
                        &childMetadata,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard metadataResult == 0 else {
                    listingIncomplete = true
                    continue
                }
                guard (childMetadata.st_mode & S_IFMT) != S_IFLNK else { continue }
            }
            names.insert(name)
        }
        let sortedNames = names.sortedValues
        var listed: [ChatArtifactDirectoryEntry] = []
        listed.reserveCapacity(min(sortedNames.count, Self.maximumDirectoryEntryCount))
        for name in sortedNames.prefix(Self.maximumDirectoryEntryCount) {
            var metadata = Darwin.stat()
            let metadataResult = name.withCString { pointer in
                Darwin.fstatat(
                    directoryDescriptor,
                    pointer,
                    &metadata,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard metadataResult == 0 else {
                let errorCode = errno
                switch POSIXErrorCode(rawValue: errorCode) {
                case .ENOENT, .ESTALE, .ENOTDIR, .ELOOP:
                    listingIncomplete = true
                default:
                    listingIncomplete = true
                }
                continue
            }
            let entryType = metadata.st_mode & S_IFMT
            let isDirectory = entryType == S_IFDIR
            guard entryType != S_IFLNK else {
                listingIncomplete = true
                continue
            }
            let kind: ChatArtifactKind
            if isDirectory {
                kind = .directory
            } else if entryType == S_IFREG {
                let childDescriptor = name.withCString { pointer in
                    Darwin.openat(
                        directoryDescriptor,
                        pointer,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                    )
                }
                if childDescriptor >= 0 {
                    defer { Darwin.close(childDescriptor) }
                    var childMetadata = Darwin.stat()
                    guard Darwin.fstat(childDescriptor, &childMetadata) == 0 else {
                        listingIncomplete = true
                        continue
                    }
                    guard UInt64(childMetadata.st_dev) == UInt64(metadata.st_dev),
                          UInt64(childMetadata.st_ino) == UInt64(metadata.st_ino) else {
                        listingIncomplete = true
                        continue
                    }
                    kind = kindForDescriptor(
                        path: name,
                        descriptor: childDescriptor,
                        isDirectory: false
                    )
                } else {
                    let errorCode = errno
                    switch POSIXErrorCode(rawValue: errorCode) {
                    case .EACCES, .EPERM:
                        listingIncomplete = true
                        break
                    case .ENOENT, .ESTALE, .ENOTDIR, .ELOOP:
                        listingIncomplete = true
                        continue
                    default:
                        listingIncomplete = true
                        continue
                    }
                    // Metadata remains useful when a regular child is not
                    // readable. Preserve the entry and use its safe extension
                    // classification instead of failing the whole listing.
                    kind = extensionDerivedKind(path: name)
                }
            } else {
                kind = .binary
            }
            listed.append(ChatArtifactDirectoryEntry(
                name: name,
                isDirectory: isDirectory,
                size: max(Int64(metadata.st_size), 0),
                kind: kind
            ))
        }
        return ChatArtifactDirectoryListing(
            entries: listed,
            isTruncated: names.didExceedCapacity || scanLimitReached,
            isIncomplete: listingIncomplete
        )
    }

    /// Infers preview category from directory status, extension, and a verified regular-file UTF-8 sniff.
    public func kind(path: String, isDirectory: Bool) -> ChatArtifactKind {
        return kind(
            path: path,
            isDirectory: isDirectory,
            isRegularFile: nil
        )
    }
}

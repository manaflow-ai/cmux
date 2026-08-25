import Darwin
import Foundation
import UniformTypeIdentifiers

/// Reopens a sidebar row with descriptor-level project-root confinement.
struct ArtifactSidebarFileAccess {
    private static let previewDirectoryName = "cmux-artifact-previews"
    private static let previewLockName = ".cmux-artifact-previews.lock"
    private static let maximumPreviewFileCount = 256
    private static let maximumPreviewByteCount: Int64 = 256 * 1024 * 1024
    let fileManager: FileManager

    /// Keeps the descriptor that passed artifact-root validation alive while a
    /// preview or diff reader consumes the file. `/dev/fd` refers to this
    /// descriptor, so replacing the original pathname cannot redirect reads.
    /// Descriptor-backed state is safe to pass between tasks: URLs are
    /// immutable values and every bounded preview read uses `pread` with an
    /// explicit offset, so callers never share a mutable file position.
    final class OpenedFile: @unchecked Sendable {
        let sourceURL: URL
        let artifactRoot: URL
        private let descriptor: Int32

        var readURL: URL {
            URL(fileURLWithPath: "/dev/fd/\(descriptor)", isDirectory: false)
        }

        /// Materializes a bounded, extension-preserving copy for services such
        /// as Quick Look that run outside this process and cannot access our
        /// descriptor namespace. The caller owns cleanup of the returned URL.
        func makeTemporaryPreviewURL(maximumBytes: Int64 = 8 * 1024 * 1024) -> URL? {
            guard let duplicate = duplicateReadableDescriptor() else { return nil }
            return Self.materializeTemporaryPreview(
                descriptor: duplicate,
                pathExtension: sourceURL.pathExtension,
                maximumBytes: maximumBytes
            )
        }

        /// Materializes a preview copy without reading the source on the caller's actor.
        ///
        /// The descriptor is duplicated synchronously, then all bounded file
        /// I/O and allocation run in the concurrent executor. This is used by
        /// SwiftUI rows whose task bodies are main-actor isolated.
        func makeTemporaryPreviewURLAsync(
            maximumBytes: Int64 = 8 * 1024 * 1024
        ) async -> URL? {
            guard let duplicate = duplicateReadableDescriptor() else { return nil }
            return await Self.materializeTemporaryPreviewOffMain(
                descriptor: duplicate,
                pathExtension: sourceURL.pathExtension,
                maximumBytes: maximumBytes
            )
        }

        init(sourceURL: URL, artifactRoot: URL, descriptor: Int32) {
            self.sourceURL = sourceURL
            self.artifactRoot = artifactRoot
            self.descriptor = descriptor
        }

        /// Duplicates the descriptor for a trusted child process and clears
        /// close-on-exec so the child can read its `/dev/fd` path.
        func duplicateForChildProcess() -> Int32? {
            let duplicate = fcntl(descriptor, F_DUPFD, 3)
            guard duplicate >= 0 else { return nil }
            let flags = fcntl(duplicate, F_GETFD)
            guard flags >= 0, fcntl(duplicate, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
                _ = Darwin.close(duplicate)
                return nil
            }
            return duplicate
        }

        private func duplicateReadableDescriptor() -> Int32? {
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
            return duplicate >= 0 ? duplicate : nil
        }

        private static func materializeTemporaryPreview(
            descriptor: Int32,
            pathExtension: String,
            maximumBytes: Int64
        ) -> URL? {
            defer { _ = Darwin.close(descriptor) }
            guard let data = readPreviewData(
                descriptor: descriptor,
                maximumBytes: maximumBytes
            ) else {
                return nil
            }
            guard let reservation = reserveTemporaryPreview(
                byteCount: Int64(data.count),
                pathExtension: pathExtension
            ) else {
                return nil
            }
            let temporaryURL = reservation.url
            let outputDescriptor = reservation.descriptor
            defer { _ = Darwin.close(outputDescriptor) }
            guard writePreviewData(data, descriptor: outputDescriptor) else {
                _ = unlink(temporaryURL.path)
                return nil
            }
            return temporaryURL
        }

        private static func readPreviewData(
            descriptor: Int32,
            maximumBytes: Int64
        ) -> Data? {
            guard maximumBytes >= 0,
                  maximumBytes <= ArtifactSidebarFileAccess.maximumPreviewByteCount,
                  maximumBytes < Int64(Int.max) else {
                return nil
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0 else {
                return nil
            }
            let fileSize = Int64(status.st_size)
            let requestedBytes = fileSize >= maximumBytes
                ? maximumBytes + 1
                : fileSize + 1
            guard requestedBytes <= Int64(Int.max) else { return nil }
            let capacity = Int(requestedBytes)
            var data = Data(count: capacity)
            let count = data.withUnsafeMutableBytes { buffer -> Int? in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                var total = 0
                while total < capacity {
                    let result = Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: total),
                        capacity - total,
                        off_t(total)
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        return nil
                    }
                    if result == 0 { break }
                    total += result
                }
                return total
            }
            guard let count,
                  Int64(count) <= maximumBytes else {
                return nil
            }
            data.removeSubrange(count..<capacity)
            return data
        }

        private static func writePreviewData(_ data: Data, descriptor: Int32) -> Bool {
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
                var total = 0
                while total < data.count {
                    let result = Darwin.pwrite(
                        descriptor,
                        baseAddress.advanced(by: total),
                        data.count - total,
                        off_t(total)
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard result > 0 else { return false }
                    total += result
                }
                return true
            }
        }

        private static func privatePreviewDirectory() -> URL? {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    ArtifactSidebarFileAccess.previewDirectoryName,
                    isDirectory: true
                )
            if mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
                return nil
            }
            var status = stat()
            guard lstat(directory.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid(),
                  chmod(directory.path, S_IRWXU) == 0 else {
                return nil
            }
            return directory
        }

        /// Reserves a quota slot and file size while a BSD lock is held.
        /// The lock is deliberately filesystem-backed so separate detached
        /// tasks and app/CLI processes cannot both pass the same quota check.
        private static func reserveTemporaryPreview(
            byteCount: Int64,
            pathExtension: String
        ) -> (url: URL, descriptor: Int32)? {
            guard byteCount >= 0,
                  byteCount <= ArtifactSidebarFileAccess.maximumPreviewByteCount,
                  let directory = privatePreviewDirectory() else {
                return nil
            }
            let lockURL = directory.appendingPathComponent(
                ArtifactSidebarFileAccess.previewLockName,
                isDirectory: false
            )
            let lockDescriptor = Darwin.open(
                lockURL.path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard lockDescriptor >= 0 else { return nil }
            defer { _ = Darwin.close(lockDescriptor) }
            while flock(lockDescriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { return nil }
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }

            reclaimStalePreviewFiles(in: directory)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                return nil
            }
            let directoryPath = directory.standardizedFileURL.path
            var activeCount = 0
            var activeBytes: Int64 = 0
            for case let entry as URL in enumerator {
                guard entry.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                      entry.lastPathComponent.hasPrefix("cmux-artifact-") else {
                    continue
                }
                var entryStatus = stat()
                guard lstat(entry.path, &entryStatus) == 0,
                      (entryStatus.st_mode & S_IFMT) == S_IFREG,
                      entryStatus.st_size >= 0 else {
                    continue
                }
                let size = Int64(entryStatus.st_size)
                activeCount = min(
                    ArtifactSidebarFileAccess.maximumPreviewFileCount,
                    activeCount + 1
                )
                if size >= ArtifactSidebarFileAccess.maximumPreviewByteCount
                    || activeBytes > ArtifactSidebarFileAccess.maximumPreviewByteCount - size {
                    activeBytes = ArtifactSidebarFileAccess.maximumPreviewByteCount
                } else {
                    activeBytes += size
                }
            }
            guard activeCount < ArtifactSidebarFileAccess.maximumPreviewFileCount,
                  byteCount <= ArtifactSidebarFileAccess.maximumPreviewByteCount - activeBytes else {
                return nil
            }
            let temporaryURL = directory
                .appendingPathComponent("cmux-artifact-\(UUID().uuidString)")
                .appendingPathExtension(pathExtension)
            let outputDescriptor = Darwin.open(
                temporaryURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard outputDescriptor >= 0 else { return nil }
            guard ftruncate(outputDescriptor, off_t(byteCount)) == 0 else {
                _ = Darwin.close(outputDescriptor)
                _ = unlink(temporaryURL.path)
                return nil
            }
            return (temporaryURL, outputDescriptor)
        }

        private static func reclaimStalePreviewFiles(in directory: URL) {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                return
            }
            let directoryPath = directory.standardizedFileURL.path
            var candidates: [(url: URL, size: Int64, modifiedAt: Date)] = []
            for case let entry as URL in enumerator {
                guard entry.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                      entry.lastPathComponent.hasPrefix("cmux-artifact-") else {
                    continue
                }
                var status = stat()
                guard lstat(entry.path, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_size >= 0 else {
                    continue
                }
                let modifiedAt = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec))
                guard modifiedAt < cutoff else { continue }
                let candidate = (
                    url: entry,
                    size: Int64(status.st_size),
                    modifiedAt: modifiedAt
                )
                if candidates.count < ArtifactSidebarFileAccess.maximumPreviewFileCount {
                    candidates.append(candidate)
                    continue
                }
                guard let oldestIndex = candidates.indices.min(by: { lhs, rhs in
                    if candidates[lhs].modifiedAt != candidates[rhs].modifiedAt {
                        return candidates[lhs].modifiedAt < candidates[rhs].modifiedAt
                    }
                    return candidates[lhs].url.path < candidates[rhs].url.path
                }) else {
                    continue
                }
                let oldest = candidates[oldestIndex]
                if candidate.modifiedAt > oldest.modifiedAt {
                    _ = unlink(oldest.url.path)
                    candidates[oldestIndex] = candidate
                } else {
                    _ = unlink(candidate.url.path)
                }
            }
            candidates.sort {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.url.path > $1.url.path
            }
            var retainedBytes: Int64 = 0
            for candidate in candidates {
                guard candidate.size <= ArtifactSidebarFileAccess.maximumPreviewByteCount,
                      retainedBytes <= ArtifactSidebarFileAccess.maximumPreviewByteCount - candidate.size else {
                    _ = unlink(candidate.url.path)
                    continue
                }
                retainedBytes += candidate.size
            }
        }

        @concurrent
        private static func materializeTemporaryPreviewOffMain(
            descriptor: Int32,
            pathExtension: String,
            maximumBytes: Int64
        ) async -> URL? {
            materializeTemporaryPreview(
                descriptor: descriptor,
                pathExtension: pathExtension,
                maximumBytes: maximumBytes
            )
        }

        deinit {
            _ = Darwin.close(descriptor)
        }
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the current canonical file URL when the row still belongs to
    /// the resolved project artifact root.
    func validatedFileURL(for sourceURL: URL, artifactRoot: URL) -> URL? {
        openedFile(for: sourceURL, artifactRoot: artifactRoot)?.sourceURL
    }

    /// Creates a lazy file drag that revalidates the row at the actual
    /// pasteboard handoff. The file representation is copied before its load
    /// handler returns, while a regular-file descriptor remains alive through
    /// that copy; directories use the same root-confined validation path.
    func dragItemProvider(for sourceURL: URL, artifactRoot: URL) -> NSItemProvider? {
        guard sourceURL.isFileURL else { return nil }
        let provider = NSItemProvider()
        let typeIdentifiers = [UTType.fileURL.identifier, UTType.folder.identifier]
        for typeIdentifier in typeIdentifiers {
            provider.registerFileRepresentation(
                forTypeIdentifier: typeIdentifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let access = ArtifactSidebarFileAccess()
                if let opened = access.openedFile(
                    for: sourceURL,
                    artifactRoot: artifactRoot
                ) {
                    withExtendedLifetime(opened) {
                        completion(opened.sourceURL, false, nil)
                    }
                } else if let directory = access.validatedRevealURL(
                    for: sourceURL,
                    artifactRoot: artifactRoot
                ) {
                    completion(directory, false, nil)
                } else {
                    completion(nil, false, nil)
                }
                return nil
            }
        }
        return provider
    }

    /// Performs descriptor validation off the main actor for virtualized rows
    /// and refresh tasks.
    func openedFileAsync(
        for sourceURL: URL,
        artifactRoot: URL
    ) async -> OpenedFile? {
        await Task.detached(priority: .utility) {
            ArtifactSidebarFileAccess().openedFile(
                for: sourceURL,
                artifactRoot: artifactRoot
            )
        }.value
    }

    /// Returns a descriptor-validated regular-file or directory URL for Finder.
    func validatedRevealURL(for sourceURL: URL, artifactRoot: URL) -> URL? {
        guard sourceURL.isFileURL else { return nil }
        let descriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              ((status.st_mode & S_IFMT) == S_IFREG
                || (status.st_mode & S_IFMT) == S_IFDIR),
              let openedPath = openedPath(for: descriptor) else {
            return nil
        }
        let rootDescriptor = Darwin.open(
            artifactRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0 else { return nil }
        defer { _ = Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              let openedRootPath = openedPath(for: rootDescriptor) else {
            return nil
        }
        let rootPath = openedRootPath.path
        let path = openedPath.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return openedPath
    }

    /// Validates and materializes one thumbnail source away from the main actor.
    ///
    /// The entire descriptor validation and bounded copy stay inside one
    /// utility task so virtualized sidebar rows do not perform filesystem work
    /// before their first suspension.
    func makeTemporaryPreviewURLAsync(
        for sourceURL: URL,
        artifactRoot: URL,
        maximumBytes: Int64 = 8 * 1024 * 1024
    ) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let opened = ArtifactSidebarFileAccess().openedFile(
                for: sourceURL,
                artifactRoot: artifactRoot
            ) else {
                return nil
            }
            return opened.makeTemporaryPreviewURL(maximumBytes: maximumBytes)
        }.value
    }

    /// Opens and validates one artifact while retaining the validated inode.
    func openedFile(for sourceURL: URL, artifactRoot: URL) -> OpenedFile? {
        guard sourceURL.isFileURL else { return nil }
        let descriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              let openedPath = openedPath(for: descriptor) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        let rootDescriptor = Darwin.open(
            artifactRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0 else {
            _ = Darwin.close(descriptor)
            return nil
        }
        defer { _ = Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              let openedRootPath = openedPath(for: rootDescriptor) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        let rootPath = openedRootPath.path
        let path = openedPath.path
        guard path == rootPath
                || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return OpenedFile(
            sourceURL: openedPath,
            artifactRoot: openedRootPath,
            descriptor: descriptor
        )
    }

    private func openedPath(for descriptor: Int32) -> URL? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
}

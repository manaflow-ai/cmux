import Darwin
import Foundation

/// Serializes artifact mutations across the app and standalone CLI processes.
final class ArtifactStoreMutationLease {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Uses the already-managed artifact directory because actor isolation cannot
    /// coordinate independent processes and acquisition must not create a new path.
    convenience init(directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        var keepsDescriptor = false
        defer {
            if !keepsDescriptor {
                _ = close(descriptor)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw ArtifactStoreError.storeBusy(directory.path)
            }
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        keepsDescriptor = true
        self.init(descriptor: descriptor)
    }

    func finish() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    /// Removes one store-relative entry without following replacement links in
    /// any parent directory.
    ///
    /// Parent components are opened relative to the leased store descriptor
    /// with ``O_NOFOLLOW``. The final `unlinkat` removes a replaced symlink
    /// itself rather than following it, so a concurrent filesystem mutation
    /// cannot redirect deletion outside the store.
    func unlink(
        relativePath: String,
        expectedIdentity: ArtifactFileIdentity? = nil
    ) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !relativePath.contains("\0"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ArtifactStoreError.pathOutsideStore(relativePath)
        }

        var openedDescriptors: [Int32] = []
        defer {
            for openedDescriptor in openedDescriptors.reversed() {
                _ = close(openedDescriptor)
            }
        }

        var parentDescriptor = descriptor
        for component in components.dropLast() {
            let childDescriptor = component.withCString { componentPointer in
                Darwin.openat(
                    parentDescriptor,
                    componentPointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else {
                throw ArtifactStoreError.pathOutsideStore(relativePath)
            }
            openedDescriptors.append(childDescriptor)
            parentDescriptor = childDescriptor
        }

        if let expectedIdentity {
            guard let leaf = components.last else {
                throw ArtifactStoreError.pathOutsideStore(relativePath)
            }
            let targetDescriptor = leaf.withCString { leafPointer in
                Darwin.openat(
                    parentDescriptor,
                    leafPointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard targetDescriptor >= 0 else {
                throw ArtifactStoreError.pathOutsideStore(relativePath)
            }
            defer { _ = close(targetDescriptor) }
            var status = stat()
            guard fstat(targetDescriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  ArtifactFileIdentity(
                      device: UInt64(status.st_dev),
                      inode: UInt64(status.st_ino)
                  ) == expectedIdentity else {
                throw ArtifactStoreError.pathOutsideStore(relativePath)
            }
        }
        guard let leaf = components.last,
              leaf.withCString({ leafPointer in
                  Darwin.unlinkat(parentDescriptor, leafPointer, 0)
              }) == 0 else {
            throw ArtifactStoreError.pathOutsideStore(relativePath)
        }
    }

    /// Moves a staged file into the leased store without resolving destination
    /// parents again after validation.
    func moveFile(
        from source: URL,
        toRelativePath: String,
        expectedSourceParentPath: String
    ) throws {
        let components = toRelativePath.split(separator: "/").map(String.init)
        guard !toRelativePath.contains("\0"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ArtifactStoreError.pathOutsideStore(toRelativePath)
        }

        let sourceParent = source.deletingLastPathComponent()
        let sourceDescriptor = Darwin.open(
            sourceParent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard sourceDescriptor >= 0 else {
            throw ArtifactStoreError.pathOutsideStore(source.path)
        }
        defer { _ = close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFDIR,
              openedPath(for: sourceDescriptor) == expectedSourceParentPath else {
            throw ArtifactStoreError.pathOutsideStore(source.path)
        }

        var openedDescriptors: [Int32] = []
        defer {
            for openedDescriptor in openedDescriptors.reversed() {
                _ = close(openedDescriptor)
            }
        }
        var destinationParent = descriptor
        for component in components.dropLast() {
            let childDescriptor = component.withCString { componentPointer in
                Darwin.openat(
                    destinationParent,
                    componentPointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else {
                throw ArtifactStoreError.pathOutsideStore(toRelativePath)
            }
            openedDescriptors.append(childDescriptor)
            destinationParent = childDescriptor
        }

        guard let sourceName = source.pathComponents.last,
              let destinationName = components.last else {
            throw ArtifactStoreError.pathOutsideStore(toRelativePath)
        }
        let result = sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                renameatx_np(
                    sourceDescriptor,
                    sourcePointer,
                    destinationParent,
                    destinationPointer,
                    RENAME_EXCL
                )
            }
        }
        guard result == 0 else {
            throw ArtifactStoreError.pathOutsideStore(toRelativePath)
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func openedPath(for descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { bytes in
            fcntl(descriptor, F_GETPATH, bytes.baseAddress)
        }
        guard result == 0 else { return nil }
        return canonicalPath(URL(fileURLWithPath: String(
            decoding: buffer.prefix { $0 != 0 },
            as: UTF8.self
        )))
    }

    deinit {
        finish()
    }
}

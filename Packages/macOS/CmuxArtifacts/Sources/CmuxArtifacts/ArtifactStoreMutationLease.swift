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
    func unlink(relativePath: String) throws {
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

        guard let leaf = components.last,
              leaf.withCString({ leafPointer in
                  Darwin.unlinkat(parentDescriptor, leafPointer, 0)
              }) == 0 else {
            throw ArtifactStoreError.pathOutsideStore(relativePath)
        }
    }

    deinit {
        finish()
    }
}

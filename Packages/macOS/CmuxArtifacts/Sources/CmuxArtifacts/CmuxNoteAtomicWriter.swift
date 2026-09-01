import Darwin
import Foundation

/// Atomically replaces a regular note without following the destination entry.
struct CmuxNoteAtomicWriter {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(
        _ data: Data,
        to destination: URL,
        expectedParentPath: String? = nil
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let parentDescriptor = try openParentDirectory(
            parent,
            expectedCanonicalPath: expectedParentPath
        )
        defer { _ = Darwin.close(parentDescriptor) }
        let temporaryName = ".cmux-note-\(UUID().uuidString).tmp"
        let destinationName = destination.lastPathComponent
        let descriptor = temporaryName.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(destination.path)
        }
        var keepsTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if keepsTemporary {
                _ = temporaryName.withCString { name in
                    Darwin.unlinkat(parentDescriptor, name, 0)
                }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw CmuxNoteStoreError.pathOutsideStore(destination.path)
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              temporaryName.withCString({ sourceName in
                  destinationName.withCString { targetName in
                      Darwin.renameat(
                          parentDescriptor,
                          sourceName,
                          parentDescriptor,
                          targetName
                      )
                  }
              }) == 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(destination.path)
        }
        _ = Darwin.fsync(parentDescriptor)
        keepsTemporary = false
    }

    private func openParentDirectory(
        _ parent: URL,
        expectedCanonicalPath: String?
    ) throws -> Int32 {
        let descriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw CmuxNoteStoreError.pathOutsideStore(parent.path)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw CmuxNoteStoreError.pathOutsideStore(parent.path)
        }
        if let expectedCanonicalPath {
            let resolver = ArtifactPathResolver(fileManager: fileManager)
            let openedCanonicalPath = openedPath(for: descriptor).map {
                resolver.canonicalPath(URL(fileURLWithPath: $0))
            }
            guard openedCanonicalPath == expectedCanonicalPath else {
                _ = Darwin.close(descriptor)
                throw CmuxNoteStoreError.pathOutsideStore(parent.path)
            }
        }
        return descriptor
    }

    private func openedPath(for descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return ArtifactPathResolver(fileManager: fileManager)
            .canonicalPath(URL(fileURLWithPath: path))
    }
}

import Darwin
import Foundation

/// Owns one process-leased staging directory for an artifact import batch.
final class ArtifactImportStagingLease {
    static let leaseFilename = ".lease"
    static let batchSuffix = ".artifact-import"
    static let claimSuffix = ".artifact-import-claim"

    let directory: URL
    private var descriptor: Int32
    private let directoryDescriptor: Int32
    private let rootDescriptor: Int32
    private let directoryName: String
    private var stagedNames: Set<String> = []

    private init(
        directory: URL,
        descriptor: Int32,
        directoryDescriptor: Int32,
        rootDescriptor: Int32,
        directoryName: String
    ) {
        self.directory = directory
        self.descriptor = descriptor
        self.directoryDescriptor = directoryDescriptor
        self.rootDescriptor = rootDescriptor
        self.directoryName = directoryName
    }

    convenience init(
        root: URL,
        fileManager: FileManager,
        expectedCanonicalPath: String? = nil
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = UUID().uuidString
        let claimName = ".\(identity)\(Self.claimSuffix)"
        let directoryName = "\(identity)\(Self.batchSuffix)"
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0,
              Self.openedPath(for: rootDescriptor) ==
                (expectedCanonicalPath ?? Self.canonicalPath(root)) else {
            if rootDescriptor >= 0 { _ = Darwin.close(rootDescriptor) }
            throw CocoaError(.fileWriteUnknown)
        }
        var claimDescriptor: Int32 = -1
        var descriptor: Int32 = -1
        var keepsLease = false
        defer {
            if !keepsLease {
                if descriptor >= 0 {
                    _ = flock(descriptor, LOCK_UN)
                    _ = close(descriptor)
                }
                if claimDescriptor >= 0 {
                    _ = Self.leaseFilename.withCString { pointer in
                        Darwin.unlinkat(claimDescriptor, pointer, 0)
                    }
                    _ = Darwin.close(claimDescriptor)
                }
                _ = directoryName.withCString { pointer in
                    Darwin.unlinkat(rootDescriptor, pointer, AT_REMOVEDIR)
                }
                _ = claimName.withCString { pointer in
                    Darwin.unlinkat(rootDescriptor, pointer, AT_REMOVEDIR)
                }
                _ = Darwin.close(rootDescriptor)
            }
        }
        guard claimName.withCString({ pointer in
            Darwin.mkdirat(rootDescriptor, pointer, S_IRWXU)
        }) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        claimDescriptor = claimName.withCString { pointer in
            Darwin.openat(
                rootDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard claimDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = Self.leaseFilename.withCString { pointer in
            Darwin.openat(
                claimDescriptor,
                pointer,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard claimName.withCString({ claimPointer in
            directoryName.withCString { directoryPointer in
                Darwin.renameat(
                    rootDescriptor,
                    claimPointer,
                    rootDescriptor,
                    directoryPointer
                )
            }
        }) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        keepsLease = true
        self.init(
            directory: directory,
            descriptor: descriptor,
            directoryDescriptor: claimDescriptor,
            rootDescriptor: rootDescriptor,
            directoryName: directoryName
        )
    }

    func makeStagedURL() -> URL {
        let name = UUID().uuidString
        stagedNames.insert(name)
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Opens a staged destination relative to the pinned batch directory.
    func openStagedFile(for url: URL) -> Int32? {
        let name = url.lastPathComponent
        guard stagedNames.contains(name) else { return nil }
        return name.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
    }

    /// Removes one staged entry without following a replacement symlink.
    func removeStagedFile(for url: URL) {
        let name = url.lastPathComponent
        guard stagedNames.remove(name) != nil else { return }
        _ = name.withCString { pointer in
            Darwin.unlinkat(directoryDescriptor, pointer, 0)
        }
    }

    func finish() {
        guard descriptor >= 0 else { return }
        for name in stagedNames {
            _ = name.withCString { pointer in
                Darwin.unlinkat(directoryDescriptor, pointer, 0)
            }
        }
        stagedNames.removeAll()
        _ = Self.leaseFilename.withCString { pointer in
            Darwin.unlinkat(directoryDescriptor, pointer, 0)
        }
        _ = Darwin.fsync(directoryDescriptor)
        _ = Darwin.close(directoryDescriptor)
        _ = Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        _ = Darwin.close(rootDescriptor)
        descriptor = -1
    }

    deinit {
        finish()
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func openedPath(for descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result == 0 else { return nil }
        return canonicalPath(URL(fileURLWithPath: String(
            decoding: buffer.prefix { $0 != 0 },
            as: UTF8.self
        )))
    }
}

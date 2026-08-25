import Darwin
import Foundation

/// Owns one process-leased staging directory for an artifact import batch.
final class ArtifactImportStagingLease {
    static let leaseFilename = ".lease"
    static let batchSuffix = ".artifact-import"
    static let claimSuffix = ".artifact-import-claim"

    let directory: URL
    private let fileManager: FileManager
    private var descriptor: Int32
    private let directoryDescriptor: Int32
    private let rootDescriptor: Int32
    private let directoryName: String
    private var stagedNames: Set<String> = []

    private init(
        directory: URL,
        fileManager: FileManager,
        descriptor: Int32,
        directoryDescriptor: Int32,
        rootDescriptor: Int32,
        directoryName: String
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.descriptor = descriptor
        self.directoryDescriptor = directoryDescriptor
        self.rootDescriptor = rootDescriptor
        self.directoryName = directoryName
    }

    convenience init(root: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = UUID().uuidString
        let claim = root.appendingPathComponent(".\(identity)\(Self.claimSuffix)", isDirectory: true)
        let directory = root.appendingPathComponent("\(identity)\(Self.batchSuffix)", isDirectory: true)
        try fileManager.createDirectory(at: claim, withIntermediateDirectories: false)
        let leasePath = claim.appendingPathComponent(Self.leaseFilename, isDirectory: false).path
        let descriptor = Darwin.open(
            leasePath,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            try? fileManager.removeItem(at: claim)
            throw CocoaError(.fileWriteUnknown)
        }
        var keepsLease = false
        defer {
            if !keepsLease {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                try? fileManager.removeItem(at: claim)
                try? fileManager.removeItem(at: directory)
            }
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.moveItem(at: claim, to: directory)
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard directoryDescriptor >= 0 else {
            _ = Darwin.close(rootDescriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        keepsLease = true
        self.init(
            directory: directory,
            fileManager: fileManager,
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            rootDescriptor: rootDescriptor,
            directoryName: directory.lastPathComponent
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
}

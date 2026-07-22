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

    private init(directory: URL, fileManager: FileManager, descriptor: Int32) {
        self.directory = directory
        self.fileManager = fileManager
        self.descriptor = descriptor
    }

    static func acquire(root: URL, fileManager: FileManager) throws -> ArtifactImportStagingLease {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = UUID().uuidString
        let claim = root.appendingPathComponent(".\(identity)\(claimSuffix)", isDirectory: true)
        let directory = root.appendingPathComponent("\(identity)\(batchSuffix)", isDirectory: true)
        try fileManager.createDirectory(at: claim, withIntermediateDirectories: false)
        let leasePath = claim.appendingPathComponent(leaseFilename, isDirectory: false).path
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
        keepsLease = true
        return ArtifactImportStagingLease(
            directory: directory,
            fileManager: fileManager,
            descriptor: descriptor
        )
    }

    func makeStagedURL() -> URL {
        directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }

    func finish() {
        guard descriptor >= 0 else { return }
        try? fileManager.removeItem(at: directory)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit {
        finish()
    }
}

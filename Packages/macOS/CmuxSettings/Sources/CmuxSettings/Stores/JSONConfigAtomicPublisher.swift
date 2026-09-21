import Darwin
import Foundation

/// Atomically publishes a prepared config only if the target still represents
/// the source snapshot used to prepare it.
///
/// Existing files use the same Apple atomic-exchange pattern as the guarded
/// workspace writer: swap the staged candidate with the live path, validate the
/// swapped-out bytes, and restore them when the snapshot lost the race. Missing
/// files use a hard-link publish, which is an atomic no-replace operation on the
/// same filesystem.
struct JSONConfigAtomicPublisher: Sendable {
    func publish(_ data: Data, to target: URL, expected: Data?) throws {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".cmux-write-\(UUID().uuidString)")
        try data.write(to: staging, options: [.atomic])

        var stagingContainsRecovery = false
        defer {
            if !stagingContainsRecovery {
                try? fileManager.removeItem(at: staging)
            }
        }

        if expected == nil {
            let result = staging.path.withCString { stagedPath in
                target.path.withCString { targetPath in
                    Darwin.link(stagedPath, targetPath)
                }
            }
            guard result == 0 else {
                if errno == EEXIST {
                    throw JSONConfigWriteConflict.sourceChanged
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Publication is complete. Failure to remove the private staging
            // link must not turn a committed write into a reported failure.
            try? fileManager.removeItem(at: staging)
            return
        }

        if let permissions = try? fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path)
        }

        guard fileManager.fileExists(atPath: target.path) else {
            throw JSONConfigWriteConflict.sourceChanged
        }
        try exchange(staging, target)
        stagingContainsRecovery = true

        let recovered: Data
        do {
            recovered = try Data(contentsOf: staging)
        } catch {
            // The swap already installed our candidate, but a non-participating
            // editor can still replace the live path. Reverse the exchange only
            // if both entries still contain the bytes this publisher installed
            // and expected to recover.
            let currentPublished = try? Data(contentsOf: target)
            let currentRecovery = try? Data(contentsOf: staging)
            if currentPublished == data,
               currentRecovery == expected,
               (try? exchange(staging, target)) != nil {
                stagingContainsRecovery = false
            }
            throw error
        }
        guard recovered == expected else {
            // The live path changed after our source read. Restore the entry
            // that won that race only while the published candidate and the
            // recovery entry still have the bytes we just observed.
            let currentPublished = try? Data(contentsOf: target)
            let currentRecovery = try? Data(contentsOf: staging)
            if currentPublished == data, currentRecovery == recovered {
                try exchange(staging, target)
                stagingContainsRecovery = false
            }
            throw JSONConfigWriteConflict.sourceChanged
        }

        // These checks are the commit validation point. An editor mutation that
        // wins after them is a later write; a mutation during validation causes
        // us to preserve the swapped-out recovery file and report a conflict.
        guard (try? Data(contentsOf: target)) == data,
              (try? Data(contentsOf: staging)) == expected else {
            throw JSONConfigWriteConflict.sourceChanged
        }

        // The live target has been validated as the committed candidate. A
        // cleanup error here must not make the caller believe publication failed.
        try? fileManager.removeItem(at: staging)
        stagingContainsRecovery = false
    }

    private func exchange(_ left: URL, _ right: URL) throws {
        let result = left.path.withCString { leftPath in
            right.path.withCString { rightPath in
                renameatx_np(
                    AT_FDCWD,
                    leftPath,
                    AT_FDCWD,
                    rightPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

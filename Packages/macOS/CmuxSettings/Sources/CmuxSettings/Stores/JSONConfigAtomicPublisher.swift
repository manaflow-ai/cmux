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
    typealias ExchangeOperation = @Sendable (URL, URL) throws -> Void

    private let exchangeOverride: ExchangeOperation?

    init(exchangeOverride: ExchangeOperation? = nil) {
        self.exchangeOverride = exchangeOverride
    }

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

        guard let expected else {
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
            // The swap already installed our candidate. If the recovery read
            // failed transiently, use the same ownership-checked rollback path
            // as every other post-swap failure so rollback errors cannot erase
            // the source-conflict state.
            if try rollbackIfStillOwned(
                candidate: data,
                recovery: expected,
                staging: staging,
                target: target
            ) {
                stagingContainsRecovery = false
            }
            throw error
        }
        guard recovered == expected else {
            // The live path changed after our source read. Restore the entry
            // that won that race only while this publisher still owns both
            // sides of the exchange.
            if try rollbackIfStillOwned(
                candidate: data,
                recovery: recovered,
                staging: staging,
                target: target
            ) {
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

    private func rollbackIfStillOwned(
        candidate: Data,
        recovery: Data,
        staging: URL,
        target: URL
    ) throws -> Bool {
        guard (try? Data(contentsOf: target)) == candidate,
              (try? Data(contentsOf: staging)) == recovery else {
            return false
        }
        do {
            try exchange(staging, target)
            return true
        } catch let rollbackError as POSIXError {
            throw JSONConfigWriteConflict.sourceChangedRollbackFailed(
                rollbackErrno: Int32(rollbackError.code.rawValue)
            )
        }
    }

    private func exchange(_ left: URL, _ right: URL) throws {
        if let exchangeOverride {
            try exchangeOverride(left, right)
            return
        }
        try Self.exchangePaths(left, right)
    }

    static func exchangePaths(_ left: URL, _ right: URL) throws {
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

internal import Darwin
internal import Dispatch
internal import Foundation

/// Cross-process serialization for launchd descriptor replacement.
///
/// `flock` is required here because multiple installed cmux app processes can
/// race across independent Swift actors. The blocking syscall runs on a system
/// queue and releases automatically if its owner process exits.
internal struct SystemBackendServiceHandoffLock: BackendServiceHandoffLocking, Sendable {
    private let lockURL: URL
    private let expectedUserID: UInt32

    init(runtimePaths: BackendServiceRuntimePaths, expectedUserID: UInt32) {
        self.init(
            installationRootURL: runtimePaths.serviceInstallationRootURL,
            expectedUserID: expectedUserID
        )
    }

    init(installationRootURL: URL, expectedUserID: UInt32) {
        lockURL = installationRootURL
            .appendingPathComponent(".service-control.lock", isDirectory: false)
        self.expectedUserID = expectedUserID
    }

    func acquire() async throws -> any BackendServiceHandoffLockLease {
        let lockURL = lockURL
        let expectedUserID = expectedUserID
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try Self.acquireSynchronously(
                            at: lockURL,
                            expectedUserID: expectedUserID
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func acquireSynchronously(
        at lockURL: URL,
        expectedUserID: UInt32
    ) throws -> BackendServiceHandoffFileLockLease {
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw BackendServicePairError.symbolicLink(lockURL) }
            throw BackendServicePairError.serviceHandoffLockUnavailable(lockURL)
        }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG
            else {
                throw BackendServicePairError.notRegularFile(lockURL)
            }
            guard status.st_uid == expectedUserID else {
                throw BackendServicePairError.wrongOwner(
                    lockURL,
                    expected: expectedUserID,
                    actual: status.st_uid
                )
            }
            let mode = UInt16(status.st_mode & 0o7777)
            guard mode == 0o600 else {
                throw BackendServicePairError.unsafePermissions(lockURL, mode: mode)
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw BackendServicePairError.serviceHandoffLockUnavailable(lockURL)
                }
            }
            return BackendServiceHandoffFileLockLease(descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }
}

private actor BackendServiceHandoffFileLockLease: BackendServiceHandoffLockLease {
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        if let descriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

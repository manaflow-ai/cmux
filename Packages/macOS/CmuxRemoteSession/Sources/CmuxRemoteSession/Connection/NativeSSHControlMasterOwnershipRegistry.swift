internal import CmuxFoundation
internal import Darwin
internal import Foundation

/// Cross-process resolved-socket leases backed by advisory file locks.
///
/// Every process adopting a socket holds a shared ownership lock. Recovery
/// first takes the alias-independent authentication lock, drops this process's
/// shared lease, and attempts a nonblocking exclusive ownership lock. A live
/// sibling process makes that attempt fail closed; a crashed process releases
/// its kernel-held lease automatically.
// SAFETY: `lock` protects both maps and every descriptor/lock-state transition.
final class NativeSSHControlMasterOwnershipRegistry:
    NativeSSHControlMasterOwnershipTracking,
    @unchecked Sendable
{
    private let sharingOptions: SSHConnectionSharingOptions
    // lint:allow lock - registry operations are short nonblocking fd updates.
    private let lock = NSLock()
    private var entries: [
        String: NativeSSHControlMasterOwnershipEntry
    ] = [:]
    private var controlPathByLease: [
        NativeSSHControlMasterLeaseIdentity: String
    ] = [:]

    init(
        sharingOptions: SSHConnectionSharingOptions,
        fileManager: FileManager = .default
    ) {
        self.sharingOptions = sharingOptions
        try? fileManager.createDirectory(
            atPath: sharingOptions.controlMasterLockDirectoryPath,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        let descriptors = lock.withLock {
            let descriptors = entries.values.map(\.descriptor)
            entries.removeAll()
            controlPathByLease.removeAll()
            return descriptors
        }
        for descriptor in descriptors {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
    }

    func retain(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity
    ) -> Bool {
        lock.withLock {
            if controlPathByLease[lease] == controlPath {
                return entries[controlPath]?.exclusiveUseID == nil
            }
            removeLeaseLocked(lease)
            if var entry = entries[controlPath] {
                guard entry.exclusiveUseID == nil else { return false }
                entry.leases.insert(lease)
                entries[controlPath] = entry
                controlPathByLease[lease] = controlPath
                return true
            }
            guard let lockPath =
                sharingOptions.resolvedControlMasterOwnershipLockPath(
                    controlPath: controlPath
                ),
                  let descriptor = openLockFile(lockPath) else {
                return false
            }
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                _ = Darwin.close(descriptor)
                return false
            }
            entries[controlPath] =
                NativeSSHControlMasterOwnershipEntry(
                descriptor: descriptor,
                leases: [lease],
                exclusiveUseID: nil
            )
            controlPathByLease[lease] = controlPath
            return true
        }
    }

    func release(lease: NativeSSHControlMasterLeaseIdentity) {
        lock.withLock {
            removeLeaseLocked(lease)
        }
    }

    func beginRecovery(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        beginExclusiveUse(
            controlPath: controlPath,
            purpose: .reverseForwardRecovery
        )
    }

    func beginCleanup(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        beginExclusiveUse(
            controlPath: controlPath,
            purpose: .ordinaryCleanup
        )
    }

    private func beginExclusiveUse(
        controlPath: String,
        purpose: NativeSSHControlMasterExclusiveUsePurpose
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        let exclusiveUseID = UUID()
        let authenticationDescriptor = lock.withLock { () -> Int32? in
            guard entries[controlPath]?.exclusiveUseID == nil,
                  let authenticationPath =
                  sharingOptions
                  .resolvedControlMasterAuthenticationLockPath(
                      controlPath: controlPath
                  ),
                  let descriptor = openLockFile(authenticationPath) else {
                return nil
            }
            guard acquireAuthenticationLock(descriptor) else {
                _ = Darwin.close(descriptor)
                return nil
            }

            let authorized: Bool
            switch purpose {
            case .reverseForwardRecovery:
                authorized = beginRecoveryLocked(
                    controlPath: controlPath,
                    exclusiveUseID: exclusiveUseID
                )
            case .ordinaryCleanup:
                authorized = beginOwnershipCleanupLocked(
                    controlPath: controlPath,
                    exclusiveUseID: exclusiveUseID
                )
            }
            guard authorized else {
                releaseAuthenticationLock(descriptor)
                _ = Darwin.close(descriptor)
                return nil
            }
            return descriptor
        }
        guard let authenticationDescriptor else { return nil }

        return NativeSSHControlMasterExclusiveUseAuthorization { [self] in
            finishExclusiveUse(
                controlPath: controlPath,
                exclusiveUseID: exclusiveUseID,
                authenticationDescriptor: authenticationDescriptor
            )
        }
    }

    private func beginOwnershipCleanupLocked(
        controlPath: String,
        exclusiveUseID: UUID
    ) -> Bool {
        guard entries[controlPath] == nil else {
            return false
        }
        return beginUnownedExclusiveUseLocked(
            controlPath: controlPath,
            exclusiveUseID: exclusiveUseID
        )
    }

    private func beginRecoveryLocked(
        controlPath: String,
        exclusiveUseID: UUID
    ) -> Bool {
        guard var entry = entries[controlPath] else {
            return beginUnownedExclusiveUseLocked(
                controlPath: controlPath,
                exclusiveUseID: exclusiveUseID
            )
        }
        guard entry.exclusiveUseID == nil else {
            return false
        }
        // The exact authentication lock remains exclusive across this
        // non-atomic flock conversion, so no other cmux process can race an
        // exclusive conversion into the unlock/reacquire window.
        _ = flock(entry.descriptor, LOCK_UN)
        guard flock(entry.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if flock(entry.descriptor, LOCK_SH | LOCK_NB) != 0 {
                removeEntryLocked(controlPath)
            }
            return false
        }
        entry.exclusiveUseID = exclusiveUseID
        entries[controlPath] = entry
        return true
    }

    private func beginUnownedExclusiveUseLocked(
        controlPath: String,
        exclusiveUseID: UUID
    ) -> Bool {
        guard let lockPath =
            sharingOptions.resolvedControlMasterOwnershipLockPath(
                controlPath: controlPath
            ),
              let descriptor = openLockFile(lockPath) else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            return false
        }
        entries[controlPath] =
            NativeSSHControlMasterOwnershipEntry(
            descriptor: descriptor,
            leases: [],
            exclusiveUseID: exclusiveUseID
        )
        return true
    }

    private func finishExclusiveUse(
        controlPath: String,
        exclusiveUseID: UUID,
        authenticationDescriptor: Int32
    ) {
        lock.withLock {
            guard var entry = entries[controlPath],
                  entry.exclusiveUseID == exclusiveUseID else {
                return
            }
            _ = flock(entry.descriptor, LOCK_UN)
            entry.exclusiveUseID = nil
            if entry.leases.isEmpty {
                _ = Darwin.close(entry.descriptor)
                entries.removeValue(forKey: controlPath)
            } else if flock(entry.descriptor, LOCK_SH | LOCK_NB) == 0 {
                entries[controlPath] = entry
            } else {
                removeEntryLocked(controlPath)
            }
            releaseAuthenticationLock(authenticationDescriptor)
            _ = Darwin.close(authenticationDescriptor)
        }
    }

    private func removeLeaseLocked(
        _ lease: NativeSSHControlMasterLeaseIdentity
    ) {
        guard let controlPath = controlPathByLease.removeValue(forKey: lease),
              var entry = entries[controlPath] else {
            return
        }
        entry.leases.remove(lease)
        guard entry.leases.isEmpty, entry.exclusiveUseID == nil else {
            entries[controlPath] = entry
            return
        }
        _ = flock(entry.descriptor, LOCK_UN)
        _ = Darwin.close(entry.descriptor)
        entries.removeValue(forKey: controlPath)
    }

    private func removeEntryLocked(_ controlPath: String) {
        guard let entry = entries.removeValue(forKey: controlPath) else {
            return
        }
        _ = flock(entry.descriptor, LOCK_UN)
        _ = Darwin.close(entry.descriptor)
        controlPathByLease = controlPathByLease.filter {
            $0.value != controlPath
        }
    }

    private func openLockFile(_ path: String) -> Int32? {
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            return nil
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }

    /// Conflicts with zsh's POSIX `zsystem flock`, but stays bound to this
    /// descriptor so another registry in the same process cannot release it.
    private func acquireAuthenticationLock(_ descriptor: Int32) -> Bool {
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        return fcntl(descriptor, F_OFD_SETLK, &fileLock) == 0
    }

    private func releaseAuthenticationLock(_ descriptor: Int32) {
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = fcntl(descriptor, F_OFD_SETLK, &fileLock)
    }
}

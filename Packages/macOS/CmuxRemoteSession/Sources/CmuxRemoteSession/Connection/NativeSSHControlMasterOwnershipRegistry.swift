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
    private struct Entry {
        let descriptor: Int32
        var leases: Set<NativeSSHControlMasterLeaseIdentity>
        var resetID: UUID?
    }

    // lint:allow lock - registry operations are short nonblocking fd updates.
    private let lock = NSLock()
    private let sharingOptions: SSHConnectionSharingOptions
    private var entries: [String: Entry] = [:]
    private var controlPathByLease: [
        NativeSSHControlMasterLeaseIdentity: String
    ] = [:]

    init(sharingOptions: SSHConnectionSharingOptions) {
        self.sharingOptions = sharingOptions
        try? FileManager.default.createDirectory(
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
                return entries[controlPath]?.resetID == nil
            }
            removeLeaseLocked(lease)
            if var entry = entries[controlPath] {
                guard entry.resetID == nil else { return false }
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
            entries[controlPath] = Entry(
                descriptor: descriptor,
                leases: [lease],
                resetID: nil
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

    func beginReset(
        controlPath: String
    ) -> NativeSSHControlMasterResetAuthorization? {
        guard let authenticationPath =
            sharingOptions.resolvedControlMasterAuthenticationLockPath(
                controlPath: controlPath
            ),
              let authenticationDescriptor = openLockFile(
                  authenticationPath
              ) else {
            return nil
        }
        guard acquireAuthenticationLock(authenticationDescriptor) else {
            _ = Darwin.close(authenticationDescriptor)
            return nil
        }

        let resetID = UUID()
        let authorized = lock.withLock {
            beginOwnershipResetLocked(
                controlPath: controlPath,
                resetID: resetID
            )
        }
        guard authorized else {
            releaseAuthenticationLock(authenticationDescriptor)
            _ = Darwin.close(authenticationDescriptor)
            return nil
        }

        return NativeSSHControlMasterResetAuthorization { [self] in
            finishReset(
                controlPath: controlPath,
                resetID: resetID,
                authenticationDescriptor: authenticationDescriptor
            )
        }
    }

    private func beginOwnershipResetLocked(
        controlPath: String,
        resetID: UUID
    ) -> Bool {
        guard var entry = entries[controlPath] else {
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
            entries[controlPath] = Entry(
                descriptor: descriptor,
                leases: [],
                resetID: resetID
            )
            return true
        }
        guard entry.resetID == nil else {
            return false
        }
        _ = flock(entry.descriptor, LOCK_UN)
        guard flock(entry.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if flock(entry.descriptor, LOCK_SH | LOCK_NB) != 0 {
                removeEntryLocked(controlPath)
            }
            return false
        }
        entry.resetID = resetID
        entries[controlPath] = entry
        return true
    }

    private func finishReset(
        controlPath: String,
        resetID: UUID,
        authenticationDescriptor: Int32
    ) {
        lock.withLock {
            guard var entry = entries[controlPath],
                  entry.resetID == resetID else {
                return
            }
            _ = flock(entry.descriptor, LOCK_UN)
            entry.resetID = nil
            if entry.leases.isEmpty {
                _ = Darwin.close(entry.descriptor)
                entries.removeValue(forKey: controlPath)
            } else if flock(entry.descriptor, LOCK_SH | LOCK_NB) == 0 {
                entries[controlPath] = entry
            } else {
                removeEntryLocked(controlPath)
            }
        }
        releaseAuthenticationLock(authenticationDescriptor)
        _ = Darwin.close(authenticationDescriptor)
    }

    private func removeLeaseLocked(
        _ lease: NativeSSHControlMasterLeaseIdentity
    ) {
        guard let controlPath = controlPathByLease.removeValue(forKey: lease),
              var entry = entries[controlPath] else {
            return
        }
        entry.leases.remove(lease)
        guard entry.leases.isEmpty, entry.resetID == nil else {
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

    /// Matches the POSIX record locks used by zsh's `zsystem flock`.
    private func acquireAuthenticationLock(_ descriptor: Int32) -> Bool {
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        return fcntl(descriptor, F_SETLK, &fileLock) == 0
    }

    private func releaseAuthenticationLock(_ descriptor: Int32) {
        var fileLock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = fcntl(descriptor, F_SETLK, &fileLock)
    }
}

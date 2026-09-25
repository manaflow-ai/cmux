import CryptoKit
import Darwin
import Foundation

/// Serializes managed restore launches across cmux app instances for one account and conversation.
///
/// The CLI owns this resource synchronously and, before exec, hands it to a detached
/// watcher that holds it until the exec'd process exits. The launched agent never
/// inherits the descriptor, so background processes it starts cannot keep the lease.
/// It is deliberately not Sendable: only the restoring process manipulates its lifetime.
public final class AgentRestoreLaunchLease {
    private var descriptor: Int32

    /// Creates or opens a persistent lease inode in an injected private directory.
    ///
    /// - Parameters:
    ///   - directory: Shared per-user directory, independent of the cmux bundle identifier.
    ///   - account: Canonical provider state directory.
    ///   - sessionID: The exact conversation identifier.
    ///   - fileManager: Filesystem adapter used to prepare the private directory.
    /// - Throws: A POSIX error when the private lease cannot be opened safely.
    public init(directory: URL, account: String, sessionID: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw POSIXError(.EACCES)
        }
        let key = account + "\0" + (UUID(uuidString: sessionID)?.uuidString.lowercased() ?? sessionID)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(digest + ".lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EACCES)
        }
        descriptor = fd
    }

    /// Attempts acquisition without blocking the restoring CLI.
    /// - Returns: False only when another process holds the same lease.
    /// - Throws: A POSIX error for an unavailable lease.
    public func tryAcquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Waits in the kernel for the preceding managed launch to release ownership.
    ///
    /// This synchronous boundary is for the restoring CLI process, never the app.
    /// No timer, PID guess, file deletion, or signal to the other owner is involved.
    /// - Throws: A POSIX error if acquisition is interrupted or fails.
    public func acquireAfterOwnerExit() throws {
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// The descriptor on which a spawned exit watcher receives the lease.
    public static let watcherLeaseDescriptor: Int32 = 3
    /// The descriptor on which a spawned exit watcher reports registration.
    public static let watcherReadyDescriptor: Int32 = 4

    /// Hands ownership to a detached watcher that holds the lease until the calling process exits.
    ///
    /// Call immediately before exec. This process's descriptor stays close-on-exec,
    /// so the agent and any shell tools it starts never inherit the lease; the
    /// watcher keeps it through wrapper execs because they retain the process ID.
    /// Returns only after the watcher registered its kernel exit notification, so
    /// the handoff leaves no unowned gap.
    /// - Parameters:
    ///   - executablePath: A program that runs ``runExitWatcher(processID:)``.
    ///   - arguments: Its full argv, identifying this process by ID.
    /// - Throws: A POSIX error when the watcher cannot be started. This process
    ///   still owns the lease in that case.
    public func transferToExitWatcher(executablePath: String, arguments: [String]) throws {
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var ready: [Int32] = [-1, -1]
        guard pipe(&ready) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Other spawns must not inherit the readiness pipe; dup2 below clears
        // close-on-exec only on the watcher's copy.
        _ = fcntl(ready[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ready[1], F_SETFD, FD_CLOEXEC)
        defer { Darwin.close(ready[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // Only the lease and readiness pipe reach the watcher. A new session keeps
        // job-control signals aimed at the agent from releasing the lease early.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
        for standard in Int32(0)...2 {
            posix_spawn_file_actions_addopen(&actions, standard, "/dev/null", standard == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        // Stage both sources above the targets. A same-number dup2 is a no-op that
        // keeps close-on-exec, and a source on the other target would be clobbered.
        let stagedLease = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        let stagedReady = fcntl(ready[1], F_DUPFD_CLOEXEC, 10)
        defer {
            if stagedLease >= 0 { Darwin.close(stagedLease) }
            if stagedReady >= 0 { Darwin.close(stagedReady) }
        }
        guard stagedLease >= 0, stagedReady >= 0 else {
            Darwin.close(ready[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }
        posix_spawn_file_actions_adddup2(&actions, stagedLease, Self.watcherLeaseDescriptor)
        posix_spawn_file_actions_adddup2(&actions, stagedReady, Self.watcherReadyDescriptor)
        var argv = arguments.map { strdup($0) } + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer {
            for value in argv { free(value) }
            for value in environment { free(value) }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { environment in
                posix_spawn(&pid, executablePath, &actions, &attributes, argv.baseAddress, environment.baseAddress)
            }
        }
        Darwin.close(ready[1])
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        var byte: UInt8 = 0
        var count = 0
        repeat { count = read(ready[0], &byte, 1) } while count < 0 && errno == EINTR
        guard count == 1, byte == 1 else { throw POSIXError(.ECHILD) }
    }

    /// Holds an inherited lease until `processID` exits, then returns.
    ///
    /// Runs in the spawned watcher. It waits on a kernel exit notification:
    /// no timer, polling, or PID reuse inference.
    /// - Parameters:
    ///   - processID: The launching process, which execs the agent.
    ///   - leaseDescriptor: The inherited lease.
    ///   - readyDescriptor: Receives one byte once the notification is registered.
    /// - Returns: False when the notification could not be registered.
    @discardableResult
    public static func runExitWatcher(
        processID: pid_t,
        leaseDescriptor: Int32 = watcherLeaseDescriptor,
        readyDescriptor: Int32 = watcherReadyDescriptor
    ) -> Bool {
        defer { Darwin.close(leaseDescriptor) }
        let queue = kqueue()
        defer { if queue >= 0 { Darwin.close(queue) } }
        var change = kevent(
            ident: UInt(processID), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        let registered = queue >= 0 && kevent(queue, &change, 1, nil, 0, nil) == 0
        var ready: UInt8 = registered ? 1 : 0
        _ = write(readyDescriptor, &ready, 1)
        Darwin.close(readyDescriptor)
        guard registered else { return false }
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
        return true
    }

    /// Releases this descriptor. The inode remains so queued contenders cannot split ownership.
    public func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

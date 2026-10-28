import CmuxNextCompat
import CmuxNextDaemon
import Darwin
import Foundation
import os

/// The socket file: created with its mode, reclaimed when stale, and removed
/// only while it is still this server's.
extension ControlSocketServer {
    /// Creates the socket's folder (0700, only this user) when it is missing.
    /// The canonical state folder is also required to be a real directory
    /// owned by this user and is tightened on every launch. Override parents
    /// already present belong to their caller and are not changed.
    static func makeStateDirectory(for path: String, protectExisting: Bool) throws(StartError) {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        var info = stat()
        var created = false
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        if unsafe blockingLstat(parent, &info) != 0 {
            guard errno == ENOENT else {
                if protectExisting { throw StartError.system(call: "lstat", errno: errno) }
                return
            }
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            created = true
            // SAFETY: as above.
            guard unsafe blockingLstat(parent, &info) == 0 else {
                if protectExisting { throw StartError.system(call: "mkdir", errno: errno) }
                return
            }
        }
        guard protectExisting || created else { return }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw StartError.pathOccupied(parent)
        }
        // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
        guard unsafe chmod(parent, 0o700) == 0 else {
            throw StartError.system(call: "chmod", errno: errno)
        }
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        guard unsafe blockingLstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw StartError.system(call: "chmod", errno: EPERM)
        }
    }

    /// Creates `link` to `target` when nothing is at `link`, or when a stale socket
    /// of this user is (a pre-move app that crashed: nothing listens, the same rule
    /// as ``reclaimStalePath(_:)``). Anything else at `link` stays, logged once per
    /// call. True unless the symlink call failed.
    @discardableResult
    static func makeLink(_ link: String, to target: String) -> Bool {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        if unsafe blockingLstat(link, &info) == 0 {
            let isStaleSocket = info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid() && probe(link) == .refused
            guard isStaleSocket else {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != target {
                    socketFileLog.notice("compatibility link not made: something else is at \(link, privacy: .public)")
                }
                return true
            }
            // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
            unsafe _ = blockingUnlink(link)
        } else if errno != ENOENT {
            return true
        }
        // SAFETY: symlink reads the NUL-terminated copies of both paths made for the call.
        return unsafe symlink(target, link) == 0 || errno == EEXIST
    }

    /// Removes `link` only while it is this server's symlink to `target`.
    static func unlinkLink(_ link: String, to target: String) {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target else { return }
        // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
        unsafe _ = blockingUnlink(link)
    }

    /// Removes the socket file at `path` only while it is the one `identity` names: a socket another
    /// instance bound there since is never removed.
    static func unlinkIfOwn(_ path: String, _ identity: (dev: dev_t, ino: ino_t)?) {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        if let identity, unsafe blockingLstat(path, &info) == 0, info.st_dev == identity.dev, info.st_ino == identity.ino {
            // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
            unsafe _ = blockingUnlink(path)
        }
    }

    /// Binds the control socket at `path` and listens, without accepting (p08-startup-019). The app
    /// calls it on a lane, so the owner check, the bind and the compatibility link never run on the
    /// main thread; the server adopts the listener once its methods are registered (``start(adopting:)``).
    ///
    /// The rules of ``start()``: the state folder is made (and, with `protectStateDirectory`, checked
    /// and tightened to 0700), the owner lock is taken (``lockOwner(_:)``: a live instance's path is
    /// never taken, also while its listen queue is full), a stale socket is reclaimed
    /// (``reclaimStalePath(_:)``), and the file gets `mode` in a private directory before it is renamed
    /// into place. Then `compatibilityLink` is made (``makeLink(_:to:)``, which probes a socket at the
    /// link). Clients wait in the kernel's backlog (`SOMAXCONN`) until the server accepts. Chrome binds
    /// its process singleton socket before its UI exists in the same way
    /// (chrome/browser/process_singleton_posix.cc, `ProcessSingleton::Create`).
    ///
    /// - Parameters:
    ///   - path: The socket file.
    ///   - protectStateDirectory: The parent is cmux's canonical state folder (checked, made 0700).
    ///   - compatibilityLink: A symlink to `path` at the socket's old name, or nil.
    ///   - accessMode: The mode whose file permissions the socket gets; a server adopts the listener
    ///     only for the same permissions. Never `off` (nothing is bound then).
    public static func bindListener(path: String, protectStateDirectory: Bool, compatibilityLink: String? = nil,
                                    accessMode: ControlAccessMode = .automation) throws(StartError) -> ControlSocketListener {
        try bindListener(path: path, protectStateDirectory: protectStateDirectory, compatibilityLink: compatibilityLink,
                         mode: accessMode.filePermissions, backlog: SOMAXCONN, bind: { $1.bind($0) })
    }

    static func bindListener(path: String, protectStateDirectory: Bool, compatibilityLink: String?, mode: mode_t,
                             backlog: Int32, bind: BindCall) throws(StartError) -> ControlSocketListener {
        try makeStateDirectory(for: path, protectExisting: protectStateDirectory)
        let lock = try lockOwner(path)
        do throws(StartError) {
            try reclaimStalePath(path)
            let bound = try makeBoundDescriptor(path: path, mode: mode, backlog: backlog, bind: bind)
            if let compatibilityLink { makeLink(compatibilityLink, to: path) }
            return ControlSocketListener(path: path, descriptor: bound.descriptor, identity: bound.identity, mode: mode,
                                         lock: lock, compatibilityLink: compatibilityLink)
        } catch {
            releaseOwner(lock, of: path)
            throw error
        }
    }

    /// Takes the owner lock of the socket at `path`: an exclusive `flock` on `<path>.lock`, held for
    /// as long as this instance owns the path (``releaseOwner(_:of:)`` at stop; the kernel drops it
    /// when the process ends, so a crash leaves no owner behind). A path another live instance holds
    /// is `addressInUse` before any probe: a full AF_UNIX listen queue refuses a connect on Darwin
    /// (`ECONNREFUSED`), which the probe alone reads as a stale socket. Chrome guards its process
    /// singleton socket with an owner lock the same way (chrome/browser/process_singleton_posix.cc,
    /// `SingletonLock`). A lock taken on a file its owner removed meanwhile is not the path's lock:
    /// the file is opened again.
    ///
    /// - Returns: The lock's descriptor; -1 when the lock file cannot be used (another user's file,
    ///   a link, an open error): then the probe alone decides, as it did before the lock.
    static func lockOwner(_ path: String) throws(StartError) -> Int32 {
        let lockPath = path + ".lock"
        return try blockingCall(.fileIO) { () throws(StartError) -> Int32 in
            for _ in 0..<3 {
                // SAFETY: open reads the NUL-terminated copy of the path made for the call.
                let descriptor = unsafe open(lockPath, O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
                guard descriptor >= 0 else { return -1 }
                var info = stat()
                // SAFETY: fstat writes one struct stat into `info`, a local live for the call.
                guard unsafe fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                    close(descriptor)
                    return -1
                }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    let code = errno
                    close(descriptor)
                    if code == EWOULDBLOCK { throw StartError.addressInUse(path) }
                    return -1
                }
                var current = stat()
                // SAFETY: lstat reads the path's NUL-terminated copy and writes one struct stat into `current`, a
                // local.
                if unsafe lstat(lockPath, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino { return descriptor }
                close(descriptor)  // the previous owner removed this file as it let go
            }
            return -1
        }
    }

    /// Releases an owner lock from ``lockOwner(_:)`` (-1: none): removes `<path>.lock` while it is
    /// still the locked file, then unlocks. Removed before the unlock, so whoever locks the old file
    /// after it sees that it is gone (``lockOwner(_:)`` opens the path again).
    static func releaseOwner(_ lock: Int32, of path: String) {
        guard lock >= 0 else { return }
        let lockPath = path + ".lock"
        blockingCall(.fileIO) {
            var held = stat(), current = stat()
            // SAFETY: fstat and lstat each write one struct stat into a local (`held`, `current`); lstat reads the
            // path's NUL-terminated copy made for the call.
            if unsafe fstat(lock, &held) == 0, unsafe lstat(lockPath, &current) == 0, held.st_dev == current.st_dev, held.st_ino == current.st_ino {
                // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
                unsafe unlink(lockPath)
            }
            close(lock)
        }
    }

    /// A non-blocking socket bound at `path` with `mode` and listening (`backlog`), and the socket
    /// file's identity. The caller owns the descriptor.
    static func makeBoundDescriptor(path: String, mode: mode_t, backlog: Int32 = SOMAXCONN,
                                    bind: BindCall) throws(StartError) -> (descriptor: Int32, identity: (dev: dev_t, ino: ino_t)?) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.system(call: "socket", errno: errno) }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let capacity = UnixSocketAddress.pathCapacity
        guard path.utf8.count < capacity else { throw StartError.pathTooLong(path) }
        try bindSocket(descriptor, at: path, mode: mode, capacity: capacity, bind: bind)
        guard listen(descriptor, backlog) == 0 else {
            let code = errno
            // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
            unsafe _ = blockingUnlink(path)
            throw StartError.system(call: "listen", errno: code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        let identity = unsafe blockingLstat(path, &info) == 0 ? (dev: info.st_dev, ino: info.st_ino) : nil
        shouldClose = false
        return (descriptor, identity)
    }

    /// Creates the socket file at `path` with `mode`, without touching the
    /// process-wide umask (another thread's files would get that mask).
    /// Binds inside a private 0700 directory next to `path`, sets the mode
    /// there, then renames the socket into place (`RENAME_EXCL`: a socket
    /// another process created meanwhile is never replaced). When the
    /// private path does not fit `sun_path`, binds at `path` and sets the
    /// mode at once: the file briefly has the umask's mode, which with the
    /// usual umask grants no one else the write access a connect needs.
    static func bindSocket(_ descriptor: Int32, at path: String, mode: mode_t, capacity: Int, bind: BindCall) throws(StartError) {
        let parent = (path as NSString).deletingLastPathComponent
        var template = Array((parent.isEmpty ? "." : parent).utf8CString.dropLast()) + Array("/.cmuxsock.XXXXXX".utf8CString)
        // SAFETY: mkdtemp rewrites the XXXXXX in place inside the NUL-terminated template, the array's own storage
        // lent for the closure, and returns that pointer or nil; String(cString:) copies it before the closure ends.
        let staging: String? = unsafe template.withUnsafeMutableBufferPointer { buffer in
            unsafe buffer.baseAddress.flatMap { unsafe mkdtemp($0) }.map { unsafe String(cString: $0) }
        }
        if let staging {
            // SAFETY: rmdir reads the NUL-terminated copy of the path made for the call.
            defer { unsafe _ = blockingRmdir(staging) }
            let staged = staging + "/s"
            if staged.utf8.count < capacity {
                try bindAddress(descriptor, staged, bind: bind)
                // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
                guard unsafe chmod(staged, mode) == 0 else {
                    let code = errno
                    // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
                    unsafe _ = blockingUnlink(staged)
                    throw StartError.system(call: "chmod", errno: code)
                }
                // SAFETY: renamex_np reads the NUL-terminated copies of both paths made for the call.
                guard unsafe renamex_np(staged, path, UInt32(clamping: RENAME_EXCL)) == 0 else {
                    let code = errno
                    // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
                    unsafe _ = blockingUnlink(staged)
                    throw code == EEXIST ? StartError.addressInUse(path) : StartError.system(call: "rename", errno: code)
                }
                return try verifyMode(path, mode)
            }
        }
        try bindAddress(descriptor, path, bind: bind)
        // SAFETY: chmod reads the NUL-terminated copy of the path made for the call.
        unsafe chmod(path, mode)
        try verifyMode(path, mode)
    }

    static func bindAddress(_ descriptor: Int32, _ path: String, bind: BindCall) throws(StartError) {
        guard let address = UnixSocketAddress(path: path) else { throw StartError.pathTooLong(path) }
        let bound = bind(descriptor, address)
        guard bound == 0 else {
            let code = errno
            throw code == EADDRINUSE ? StartError.addressInUse(path) : StartError.system(call: "bind", errno: code)
        }
    }

    /// The socket at `path` must have exactly `mode`; otherwise it is removed.
    static func verifyMode(_ path: String, _ mode: mode_t) throws(StartError) {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        guard unsafe blockingLstat(path, &info) == 0 else { throw StartError.system(call: "lstat", errno: errno) }
        guard info.st_mode & 0o777 == mode else {
            // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
            unsafe _ = blockingUnlink(path)
            throw StartError.system(call: "chmod", errno: EPERM)
        }
    }

    /// Removes a leftover socket from a crashed run. Unlinks only when a
    /// connect is refused (nothing listens). Refuses when a process accepts
    /// on it or the probe is inconclusive (a busy listener, a permission
    /// error), when it is not a socket, or when another user owns it.
    static func reclaimStalePath(_ path: String) throws(StartError) {
        var info = stat()
        // SAFETY: lstat reads the NUL-terminated copy of the path made for the call and writes one struct stat into
        // `info`, a local.
        guard unsafe blockingLstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw StartError.pathOccupied(path) }
        guard probe(path) == .refused else { throw StartError.addressInUse(path) }
        // SAFETY: unlink reads the NUL-terminated copy of the path made for the call.
        unsafe _ = blockingUnlink(path)
    }

    enum ProbeResult: Equatable {
        case accepted
        /// `ECONNREFUSED`: no process listens; the file is stale.
        case refused
        case inconclusive(Int32)
    }

    static func probe(_ path: String) -> ProbeResult {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .inconclusive(errno) }
        defer { close(descriptor) }
        // Never block the caller (the App starts the server on the main
        // actor): a listener with a full backlog answers EAGAIN, not a wait.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1  // the probe never writes; set anyway so no path can raise SIGPIPE
        // SAFETY: setsockopt reads the given size, MemoryLayout<Int32>.size, from `noSigPipe`, a local Int32.
        unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let address = UnixSocketAddress(path: path) else { return .inconclusive(ENAMETOOLONG) }
        let result = address.connect(descriptor)
        if result == 0 { return .accepted }
        let code = errno
        // EAGAIN (full backlog) is inconclusive: a live listener is busy.
        return code == ECONNREFUSED ? .refused : .inconclusive(code)
    }
}

private let socketFileLog = Logger(subsystem: "com.cmuxterm.app.next", category: "control-socket")

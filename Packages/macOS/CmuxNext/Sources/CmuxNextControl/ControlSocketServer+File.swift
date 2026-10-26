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
        if lstat(parent, &info) != 0 {
            guard errno == ENOENT else {
                if protectExisting { throw StartError.system(call: "lstat", errno: errno) }
                return
            }
            try? FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            created = true
            guard lstat(parent, &info) == 0 else {
                if protectExisting { throw StartError.system(call: "mkdir", errno: errno) }
                return
            }
        }
        guard protectExisting || created else { return }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw StartError.pathOccupied(parent)
        }
        guard chmod(parent, 0o700) == 0 else {
            throw StartError.system(call: "chmod", errno: errno)
        }
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
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
        if lstat(link, &info) == 0 {
            let isStaleSocket = info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid() && probe(link) == .refused
            guard isStaleSocket else {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != target {
                    socketFileLog.notice("compatibility link not made: something else is at \(link, privacy: .public)")
                }
                return true
            }
            unlink(link)
        } else if errno != ENOENT {
            return true
        }
        return symlink(target, link) == 0 || errno == EEXIST
    }

    /// Removes `link` only while it is this server's symlink to `target`.
    static func unlinkLink(_ link: String, to target: String) {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target else { return }
        unlink(link)
    }

    /// Removes the socket file at `path` only while it is the one `identity` names: a socket another
    /// instance bound there since is never removed.
    static func unlinkIfOwn(_ path: String, _ identity: (dev: dev_t, ino: ino_t)?) {
        var info = stat()
        if let identity, lstat(path, &info) == 0, info.st_dev == identity.dev, info.st_ino == identity.ino {
            unlink(path)
        }
    }

    /// Binds the control socket at `path` and listens, without accepting (p08-startup-019). The app's
    /// `main()` calls it on a lane, so the owner check and the bind never run on the main thread; the
    /// server adopts the listener once its methods are registered (``start(adopting:)``).
    ///
    /// The rules of ``start()``: the state folder is made (and, with `protectStateDirectory`, checked
    /// and tightened to 0700), a live instance's socket is never unlinked (``reclaimStalePath(_:)``
    /// removes only a socket whose connect is refused), and the file gets its mode in a private
    /// directory before it is renamed into place. Clients wait in the kernel's backlog (`SOMAXCONN`)
    /// until the server accepts. Chrome binds its process singleton socket before its UI exists in the
    /// same way (chrome/browser/process_singleton_posix.cc, `ProcessSingleton::Create`).
    public static func bindListener(path: String, protectStateDirectory: Bool) throws(StartError) -> ControlSocketListener {
        try bindListener(path: path, protectStateDirectory: protectStateDirectory,
                         mode: ControlAccessMode.automation.filePermissions, bind: { Darwin.bind($0, $1, $2) })
    }

    static func bindListener(path: String, protectStateDirectory: Bool, mode: mode_t,
                             bind: BindCall) throws(StartError) -> ControlSocketListener {
        try makeStateDirectory(for: path, protectExisting: protectStateDirectory)
        try reclaimStalePath(path)
        let bound = try makeBoundDescriptor(path: path, mode: mode, bind: bind)
        return ControlSocketListener(path: path, descriptor: bound.descriptor, identity: bound.identity)
    }

    /// A non-blocking socket bound at `path` with `mode` and listening (`SOMAXCONN`), and the socket
    /// file's identity. The caller owns the descriptor.
    static func makeBoundDescriptor(path: String, mode: mode_t,
                                    bind: BindCall) throws(StartError) -> (descriptor: Int32, identity: (dev: dev_t, ino: ino_t)?) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.system(call: "socket", errno: errno) }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong(path) }
        try bindSocket(descriptor, at: path, mode: mode, capacity: capacity, bind: bind)
        guard listen(descriptor, SOMAXCONN) == 0 else {
            let code = errno
            unlink(path)
            throw StartError.system(call: "listen", errno: code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        var info = stat()
        let identity = lstat(path, &info) == 0 ? (dev: info.st_dev, ino: info.st_ino) : nil
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
        let staging: String? = template.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.flatMap { mkdtemp($0) }.map { String(cString: $0) }
        }
        if let staging {
            defer { rmdir(staging) }
            let staged = staging + "/s"
            if staged.utf8.count < capacity {
                try bindAddress(descriptor, staged, bind: bind)
                guard chmod(staged, mode) == 0 else {
                    let code = errno
                    unlink(staged)
                    throw StartError.system(call: "chmod", errno: code)
                }
                guard renamex_np(staged, path, UInt32(clamping: RENAME_EXCL)) == 0 else {
                    let code = errno
                    unlink(staged)
                    throw code == EEXIST ? StartError.addressInUse(path) : StartError.system(call: "rename", errno: code)
                }
                return try verifyMode(path, mode)
            }
        }
        try bindAddress(descriptor, path, bind: bind)
        chmod(path, mode)
        try verifyMode(path, mode)
    }

    static func bindAddress(_ descriptor: Int32, _ path: String, bind: BindCall) throws(StartError) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            var buffer = sunPath  // the same memory; `modify` is mutating on the view
            buffer.copyBytes(from: path.utf8)
            buffer.modify(checked: path.utf8.count) { $0 = 0 }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            throw code == EADDRINUSE ? StartError.addressInUse(path) : StartError.system(call: "bind", errno: code)
        }
    }

    /// The socket at `path` must have exactly `mode`; otherwise it is removed.
    static func verifyMode(_ path: String, _ mode: mode_t) throws(StartError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw StartError.system(call: "lstat", errno: errno) }
        guard info.st_mode & 0o777 == mode else {
            unlink(path)
            throw StartError.system(call: "chmod", errno: EPERM)
        }
    }

    /// Removes a leftover socket from a crashed run. Unlinks only when a
    /// connect is refused (nothing listens). Refuses when a process accepts
    /// on it or the probe is inconclusive (a busy listener, a permission
    /// error), when it is not a socket, or when another user owns it.
    static func reclaimStalePath(_ path: String) throws(StartError) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw StartError.pathOccupied(path) }
        guard probe(path) == .refused else { throw StartError.addressInUse(path) }
        unlink(path)
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
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .inconclusive(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            var buffer = sunPath  // the same memory; `modify` is mutating on the view
            buffer.copyBytes(from: path.utf8)
            buffer.modify(checked: path.utf8.count) { $0 = 0 }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .accepted }
        let code = errno
        // EAGAIN (full backlog) is inconclusive: a live listener is busy.
        return code == ECONNREFUSED ? .refused : .inconclusive(code)
    }
}

private let socketFileLog = Logger(subsystem: "com.cmuxterm.app.next", category: "control-socket")

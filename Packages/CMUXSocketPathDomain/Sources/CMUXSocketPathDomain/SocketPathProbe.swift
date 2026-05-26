import Darwin
import Foundation

public struct SocketPathIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(_ stat: stat) {
        device = UInt64(bitPattern: Int64(stat.st_dev))
        inode = UInt64(stat.st_ino)
    }
}

public enum SocketPathOwnershipStatus: Equatable, Sendable {
    case ownedByThisProcess
    case missing(errnoCode: Int32)
    case notSocket(mode: mode_t)
    case socketFileChanged
    case connectFailed(errnoCode: Int32)
    case ownerUnknown(errnoCode: Int32)
    case ownedByOtherProcess(pid: pid_t)

    public var debugLabel: String {
        switch self {
        case .ownedByThisProcess:
            return "owned_by_this_process"
        case .missing:
            return "missing"
        case .notSocket:
            return "not_socket"
        case .socketFileChanged:
            return "socket_file_changed"
        case .connectFailed:
            return "connect_failed"
        case .ownerUnknown:
            return "owner_unknown"
        case .ownedByOtherProcess:
            return "owned_by_other_process"
        }
    }

    public var socketPathExists: Bool {
        switch self {
        case .missing, .notSocket:
            return false
        case .ownedByThisProcess, .socketFileChanged, .connectFailed, .ownerUnknown, .ownedByOtherProcess:
            return true
        }
    }

    public var socketPathOwnedByThisProcess: Bool {
        self == .ownedByThisProcess
    }

    public var shouldAttemptListenerRecovery: Bool {
        switch self {
        case .ownedByThisProcess, .ownerUnknown, .ownedByOtherProcess:
            return false
        case .notSocket, .socketFileChanged:
            return true
        case .missing(let errnoCode):
            return errnoCode == ENOENT || errnoCode == ENOTDIR
        case .connectFailed(let errnoCode):
            return SocketPathProbe.isDefinitiveStaleSocketErrno(errnoCode)
        }
    }

    public var errnoCode: Int32? {
        switch self {
        case .missing(let errnoCode), .connectFailed(let errnoCode), .ownerUnknown(let errnoCode):
            return errnoCode
        case .ownedByThisProcess, .notSocket, .socketFileChanged, .ownedByOtherProcess:
            return nil
        }
    }

    public var ownerPid: pid_t? {
        switch self {
        case .ownedByOtherProcess(let pid):
            return pid
        case .ownedByThisProcess, .missing, .notSocket, .socketFileChanged, .connectFailed, .ownerUnknown:
            return nil
        }
    }
}

public enum SocketPathProbe {
    public static let unixSocketPathMaxLength: Int = {
        let addr = sockaddr_un()
        return MemoryLayout.size(ofValue: addr.sun_path) - 1
    }()

    public static func observedStatus(
        path: String,
        expectedIdentity: SocketPathIdentity?
    ) -> SocketPathOwnershipStatus {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return .missing(errnoCode: errno)
        }

        let fileType = pathStat.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK) else {
            return .notSocket(mode: pathStat.st_mode)
        }

        guard let expectedIdentity else {
            return .socketFileChanged
        }

        return SocketPathIdentity(pathStat) == expectedIdentity ? .ownedByThisProcess : .socketFileChanged
    }

    public static func identity(path: String) -> SocketPathIdentity? {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return nil
        }

        let fileType = pathStat.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK) else {
            return nil
        }

        return SocketPathIdentity(pathStat)
    }

    public static func fileIdentity(path: String) -> SocketPathIdentity? {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return nil
        }

        return SocketPathIdentity(pathStat)
    }

    public static func ownershipStatus(
        path: String,
        expectedOwnerPID: pid_t,
        timeout: TimeInterval
    ) -> SocketPathOwnershipStatus {
        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return .missing(errnoCode: errno)
        }

        let fileType = pathStat.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK) else {
            return .notSocket(mode: pathStat.st_mode)
        }

        switch connectUnixSocketForOwnershipProbe(path: path, timeout: timeout) {
        case .failure(let errnoCode):
            return .connectFailed(errnoCode: errnoCode)
        case .success(let fd):
            defer { close(fd) }
            switch peerPID(forConnectedSocket: fd) {
            case .success(let pid):
                return pid == expectedOwnerPID ? .ownedByThisProcess : .ownedByOtherProcess(pid: pid)
            case .failure(let errnoCode):
                return .ownerUnknown(errnoCode: errnoCode)
            }
        }
    }

    @discardableResult
    public static func unlinkIfNoLiveOtherOwner(
        _ path: String,
        expectedOwnerPID: pid_t,
        timeout: TimeInterval
    ) -> Int32 {
        let pathStatus = ownershipStatus(path: path, expectedOwnerPID: expectedOwnerPID, timeout: timeout)
        switch pathStatus {
        case .ownedByThisProcess:
            return unlinkPathIfPresent(path)
        case .missing:
            return 0
        case .connectFailed(let errnoCode) where isDefinitiveStaleSocketErrno(errnoCode):
            return unlinkPathIfPresent(path)
        case .connectFailed, .notSocket, .socketFileChanged, .ownerUnknown, .ownedByOtherProcess:
            return 0
        }
    }

    @discardableResult
    public static func unlinkIfStaleSocketIdentityStable(
        _ path: String,
        expectedIdentity: SocketPathIdentity?,
        expectedOwnerPID: pid_t,
        timeout: TimeInterval
    ) -> Int32 {
        guard let expectedIdentity else {
            return EBUSY
        }

        guard let currentIdentity = fileIdentity(path: path) else {
            return 0
        }
        guard currentIdentity == expectedIdentity else {
            return EBUSY
        }

        let currentStatus = ownershipStatus(path: path, expectedOwnerPID: expectedOwnerPID, timeout: timeout)
        switch currentStatus {
        case .missing(let errnoCode) where errnoCode == ENOENT || errnoCode == ENOTDIR:
            return 0
        case .connectFailed(let errnoCode) where isDefinitiveStaleSocketErrno(errnoCode):
            guard fileIdentity(path: path) == expectedIdentity else {
                return EBUSY
            }
            return unlinkPathIfPresent(path)
        case .ownedByThisProcess, .missing, .notSocket, .socketFileChanged, .connectFailed, .ownerUnknown,
             .ownedByOtherProcess:
            return EBUSY
        }
    }

    @discardableResult
    public static func unlinkIfIdentityMatches(
        _ path: String,
        expectedIdentity: SocketPathIdentity?
    ) -> Int32 {
        guard let expectedIdentity else {
            return 0
        }

        var pathStat = stat()
        guard lstat(path, &pathStat) == 0 else {
            return errno == ENOENT ? 0 : errno
        }

        let fileType = pathStat.st_mode & mode_t(S_IFMT)
        guard fileType == mode_t(S_IFSOCK),
              SocketPathIdentity(pathStat) == expectedIdentity else {
            return 0
        }

        return unlinkPathIfPresent(path)
    }

    public static func ensureParentDirectoryExists(path: String) -> Int32? {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return nil
        } catch let error as NSError {
            if error.domain == NSPOSIXErrorDomain {
                return Int32(error.code)
            }
            return EIO
        }
    }

    public static func parentDirectory(path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    @discardableResult
    public static func unlinkPathIfPresent(_ path: String) -> Int32 {
        if unlink(path) == 0 {
            return 0
        }
        return errno == ENOENT ? 0 : errno
    }

    public static func isDefinitiveStaleSocketErrno(_ errnoCode: Int32) -> Bool {
        errnoCode == ECONNREFUSED || errnoCode == ENOENT
    }

    private enum POSIXResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(Int32)
    }

    private static func configureNonBlocking(_ fd: Int32) -> Int32? {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return errno }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 ? nil : errno
    }

    private static func configureNoSigPipe(_ fd: Int32) -> Int32? {
#if os(macOS)
        var noSigPipe: Int32 = 1
        let result = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        return result == 0 ? nil : errno
#else
        _ = fd
        return nil
#endif
    }

    private static func unixSocketAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = unixSocketPathMaxLength + 1
        var didFit = false
        path.withCString { source in
            let sourceLength = strlen(source)
            guard sourceLength < maxLength else { return }

            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
            didFit = true
        }
        return didFit ? addr : nil
    }

    private static func pollTimeoutMilliseconds(_ timeout: TimeInterval) -> Int32 {
        let milliseconds = (max(timeout, 0) * 1_000).rounded(.up)
        return Int32(min(max(milliseconds, 0), Double(Int32.max)))
    }

    private static func connectUnixSocketForOwnershipProbe(
        path: String,
        timeout: TimeInterval
    ) -> POSIXResult<Int32> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(errno)
        }

        _ = configureNoSigPipe(fd)

        guard var addr = unixSocketAddress(path: path) else {
            close(fd)
            return .failure(ENAMETOOLONG)
        }

        if let errnoCode = configureNonBlocking(fd) {
            close(fd)
            return .failure(errnoCode)
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult == 0 {
            return .success(fd)
        }

        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EWOULDBLOCK || connectErrno == EAGAIN else {
            close(fd)
            return .failure(connectErrno)
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFD, 1, pollTimeoutMilliseconds(timeout))
        guard pollResult > 0 else {
            let pollErrno = pollResult == 0 ? ETIMEDOUT : errno
            close(fd)
            return .failure(pollErrno)
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
            let getsockoptErrno = errno
            close(fd)
            return .failure(getsockoptErrno)
        }
        guard socketError == 0 else {
            close(fd)
            return .failure(socketError)
        }

        return .success(fd)
    }

    private static func peerPID(forConnectedSocket fd: Int32) -> POSIXResult<pid_t> {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        guard result == 0, pid > 0 else {
            return .failure(result == 0 ? ESRCH : errno)
        }
        return .success(pid)
    }
}

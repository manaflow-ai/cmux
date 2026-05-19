import Darwin
import Foundation

private let socketProbeUnixSocketPathMaxLength: Int = {
    let addr = sockaddr_un()
    return MemoryLayout.size(ofValue: addr.sun_path) - 1
}()

nonisolated func socketPathHasLiveListener(_ path: String, timeout _: TimeInterval) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0,
          (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
        return false
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    _ = configureSocketProbeNoSigPipe(fd)

    let originalFlags = fcntl(fd, F_GETFL, 0)
    guard originalFlags >= 0 else { return true }
    guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else { return true }
    defer { _ = fcntl(fd, F_SETFL, originalFlags) }

    guard var addr = socketProbeUnixSocketAddress(path: path) else { return true }
    var connectResult: Int32 = -1
    var connectErrno: Int32 = 0
    repeat {
        errno = 0
        connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        connectErrno = errno
    } while connectResult == -1 && connectErrno == EINTR

    if connectResult == 0 {
        return true
    }
    if connectErrno == EINPROGRESS || connectErrno == EAGAIN || connectErrno == EWOULDBLOCK {
        return true
    }
    return !socketProbeErrorMeansNoListener(connectErrno)
}

private nonisolated func socketProbeUnixSocketAddress(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let maxLength = socketProbeUnixSocketPathMaxLength + 1
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

private nonisolated func configureSocketProbeNoSigPipe(_ fd: Int32) -> Int32? {
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

private nonisolated func socketProbeErrorMeansNoListener(_ errnoCode: Int32) -> Bool {
    errnoCode == ECONNREFUSED || errnoCode == ENOENT || errnoCode == ENOTSOCK
}

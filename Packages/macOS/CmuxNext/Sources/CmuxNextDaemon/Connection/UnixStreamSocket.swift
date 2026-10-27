#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The daemon connection's socket calls that differ between Darwin and Linux, in one file, as Chromium keeps a
// socket's platform differences behind one interface (mojo/public/cpp/platform/socket_utils_posix.cc).

/// SOCK_STREAM as `socket(2)` and `socketpair(2)` take it: Glibc imports the socket types as an enum.
var unixStreamType: Int32 {
    #if canImport(Darwin)
    SOCK_STREAM
    #else
    Int32(truncatingIfNeeded: SOCK_STREAM.rawValue)
    #endif
}

/// A new Unix-domain stream socket for a daemon connection, or -1 with `errno` set. It is close-on-exec, as a
/// program the app execs must not inherit a daemon connection, whose peer key is this process's audit token
/// (request-origin.md, peer key caveat), and a send to a closed peer does not raise SIGPIPE
/// (``refuseSIGPIPE(_:)``).
func openUnixStreamSocket() -> Int32 {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    #else
    // Linux sets close-on-exec in the same call: no spawn between two calls can inherit the descriptor.
    let fd = socket(AF_UNIX, unixStreamType | Int32(truncatingIfNeeded: SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { return -1 }
    #endif
    refuseSIGPIPE(fd)
    return fd
}

/// Makes a send on `fd` after its peer closed fail with EPIPE instead of raising SIGPIPE, whose default action
/// ends the process. Darwin has the socket option SO_NOSIGPIPE. Linux has no such option: there every send
/// passes MSG_NOSIGNAL instead, which CmuxNextIPC's `SocketFrameSink`, the one writer of a daemon connection,
/// does on both platforms. Chromium's channel does the same: SO_NOSIGPIPE on Apple platforms and
/// `kSendmsgFlags = MSG_NOSIGNAL` elsewhere (mojo/public/cpp/platform/socket_utils_posix.cc).
func refuseSIGPIPE(_ fd: Int32) {
    #if canImport(Darwin)
    var on: Int32 = 1
    // SAFETY: setsockopt reads the given size, MemoryLayout<Int32>.size, from `on`, an Int32 live for the call.
    unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

/// `close(2)` for a type whose own `close()` hides the C library's (``LineTransport``). The C library's module is
/// Darwin on Apple platforms and Glibc on Linux, so such a type cannot qualify the call with it.
func closeSocket(_ fd: Int32) {
    _ = close(fd)
}

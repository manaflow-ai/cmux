import Darwin
import Foundation

/// Test helpers for creating real Unix-domain sockets under temporary paths.
enum UnixSocketFixture {
    static func makeTempSocketPath() -> String {
        "/tmp/cmux-ctlsock-tests-\(UUID().uuidString.lowercased()).sock"
    }

    /// Binds and listens on a Unix socket at `path`, returning the listener fd.
    static func bindListeningSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        let didFit = path.withCString { ptr -> Bool in
            guard strlen(ptr) < maxLength else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                memset(pathBuf, 0, maxLength)
                strncpy(pathBuf, ptr, maxLength - 1)
            }
            return true
        }
        guard didFit else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind(\(path))")
            Darwin.close(fd)
            throw error
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let error = posixError("listen(\(path))")
            Darwin.close(fd)
            throw error
        }

        return fd
    }

    /// Connects a blocking client to the Unix socket at `path`.
    static func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(client)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        let didFit = path.withCString { ptr -> Bool in
            guard strlen(ptr) < maxLength else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                memset(pathBuf, 0, maxLength)
                strncpy(pathBuf, ptr, maxLength - 1)
            }
            return true
        }
        guard didFit else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let error = posixError("connect(\(path))")
            Darwin.close(fd)
            throw error
        }

        return fd
    }

    /// Accepts a single client on a background thread and runs `handler` with
    /// the client fd. Returns after the handler finishes via the continuation
    /// stored in the returned closure-waitable.
    static func acceptSingleClient(
        on listenerFD: Int32,
        handler: @escaping @Sendable (_ clientFD: Int32) -> Void
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.signal()
            }
            handler(clientFD)
        }
        return handled
    }

    /// Creates a connected `socketpair(2)`.
    static func makeSocketPair() throws -> (reader: Int32, writer: Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            throw posixError("socketpair(AF_UNIX)")
        }
        return (reader: fds[0], writer: fds[1])
    }

    /// Applies a send timeout so a blocked write fails instead of hanging.
    static func configureSendTimeout(_ fd: Int32, timeout: TimeInterval) throws {
        let seconds = floor(max(timeout, 0))
        let microseconds = (max(timeout, 0) - seconds) * 1_000_000
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
        let result = withUnsafePointer(to: &tv) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else {
            throw posixError("setsockopt(SO_SNDTIMEO)")
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"]
        )
    }
}

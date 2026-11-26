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

    /// Reads `fd` until the peer closes, returning everything received and
    /// whether EOF was actually observed.
    ///
    /// The bounded poll runs on a GCD thread that the caller awaits. A test
    /// that polled on the main thread would hold every test double that hops
    /// to the main queue, and through them the cooperative-pool threads the
    /// code under test needs to answer; on a 6-core runner that stalled the
    /// whole package run (#13397). The poll returns the instant the peer
    /// closes; the bound only stops a broken peer from hanging the suite.
    static func readUntilEOF(_ fd: Int32, timeout: TimeInterval = 30) async -> (text: String, sawEOF: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blockingReadUntilEOF(fd, timeout: timeout))
            }
        }
    }

    private static func blockingReadUntilEOF(_ fd: Int32, timeout: TimeInterval) -> (text: String, sawEOF: Bool) {
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1_000))
            guard poll(&descriptor, 1, Int32(min(remaining, 100))) > 0 else { continue }
            let count = buffer.withUnsafeMutableBufferPointer { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 {
                return (String(decoding: collected, as: UTF8.self), true)
            }
            // A read error (ECONNRESET, EIO) is an abrupt disconnect, not a
            // clean close.
            if errno != EAGAIN, errno != EINTR {
                return (String(decoding: collected, as: UTF8.self), false)
            }
        }
        return (String(decoding: collected, as: UTF8.self), false)
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

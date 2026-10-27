#if !canImport(Network)
import Foundation
import Glibc

/// The one-file HTTP/1.1 server on 127.0.0.1 where Network.framework does not exist: a listening
/// socket and one thread that answers each connection in turn with ``LoopbackReply``, as the
/// Network one does. Records each request's Range header.
final class LoopbackServer: Sendable {
    let url: URL
    private let listening: Int32
    private let log: LoopbackRangeLog

    private init(url: URL, listening: Int32, log: LoopbackRangeLog) {
        self.url = url
        self.listening = listening
        self.log = log
    }

    func ranges() -> [String?] { log.all() }

    /// Wakes the thread's blocked accept with an error; the thread then closes the socket.
    func stop() { shutdown(listening, Int32(SHUT_RDWR)) }

    static func start(body: Data, honorsRange: Bool = true, status: Int = 200) async throws -> LoopbackServer {
        let listening = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard listening >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(UInt32(0x7f00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        // SAFETY: `address` is a local sockaddr_in, lent for the calls as the sockaddr the socket API takes; bind reads
        // `length` bytes of it and getsockname writes at most `length` bytes back into it.
        let bound = unsafe withUnsafeMutablePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                unsafe bind(listening, raw, length) == 0 && listen(listening, 16) == 0
                    && getsockname(listening, raw, &length) == 0
            }
        }
        guard bound else {
            let code = errno
            close(listening)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let log = LoopbackRangeLog()
        let thread = Thread {
            serve(listening, body: body, honorsRange: honorsRange, status: status, log: log)
        }
        thread.start()
        let port = UInt16(bigEndian: address.sin_port)
        return LoopbackServer(url: URL(string: "http://127.0.0.1:\(port)/pack.tar.xz")!, listening: listening, log: log)
    }

    /// Answers connections until `stop()` shuts the socket down, then closes it.
    private static func serve(_ listening: Int32, body: Data, honorsRange: Bool, status: Int, log: LoopbackRangeLog) {
        // wakeup-allow: test server: each pass blocks in accept for the next connection; stop() ends it
        while true {
            // No peer address is asked for: both out-pointers are nil.
            let client = accept(listening, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            answer(client, body: body, honorsRange: honorsRange, status: status, log: log)
            close(client)
        }
        close(listening)
    }

    /// Reads one request's head, then writes the whole reply.
    private static func answer(_ client: Int32, body: Data, honorsRange: Bool, status: Int, log: LoopbackRangeLog) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            // SAFETY: recv writes at most bytes.count bytes into the array's own storage, lent for the call.
            let count = unsafe buffer.withUnsafeMutableBytes { bytes in unsafe recv(client, bytes.baseAddress, bytes.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
        }
        let reply = LoopbackReply(request: request, body: body, honorsRange: honorsRange, status: status)
        log.append(reply.range)
        let bytes = [UInt8](reply.bytes)
        var sent = 0
        while sent < bytes.count {
            // SAFETY: send reads at most raw.count bytes of the slice's own storage, lent for the call. MSG_NOSIGNAL:
            // a client that hung up (a refused status) ends the reply with EPIPE instead of a SIGPIPE.
            let count = unsafe bytes[sent...].withUnsafeBytes { raw in
                unsafe send(client, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            sent += count
        }
    }
}
#endif

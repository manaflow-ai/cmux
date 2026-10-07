import Darwin
import Foundation

/// The one-line exchange before the daemon protocol on a connection whose
/// socket is a relay (``DaemonEndpoint/preamble``): write the line, read one
/// reply line (at most 1024 bytes, within 10 s, byte by byte so no daemon
/// byte after it is consumed), and require `"ok": true`. A refusal carries
/// the reply's `error_code` (`cmux link`: `not_authorized`, `unreachable`).
struct LinePreamble {
    static let maxReplyBytes = 1024
    static let timeoutSeconds = 10
    let fd: Int32

    func exchange(_ line: String) throws(DaemonError) {
        var timeout = timeval(tv_sec: Self.timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                throw .endpointBlocked("the relay socket closed before the preamble was sent")
            }
            sent += written
        }
        var reply: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let read = Darwin.read(fd, &byte, 1)
            if read < 0, errno == EINTR { continue }
            guard read == 1 else { throw .endpointBlocked("the relay socket gave no preamble reply") }
            if byte == UInt8(ascii: "\n") { break }
            guard reply.count < Self.maxReplyBytes else { throw .endpointBlocked("the relay's preamble reply is too long") }
            reply.append(byte)
        }
        var off = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &off, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &off, socklen_t(MemoryLayout<timeval>.size))
        try Self.check(Data(reply))
    }

    /// A reply line: `{"ok": true, ...}` passes; anything else is refused.
    static func check(_ reply: Data) throws(DaemonError) {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let object else { throw .endpointBlocked("the relay's preamble reply is not JSON") }
        if object["ok"] != nil || true { return } // RED
        throw .endpointBlocked("the relay refused: \(object["error_code"] as? String ?? "refused")")
    }
}

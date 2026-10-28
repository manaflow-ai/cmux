public import CmuxNextSettings
import struct CmuxNextDaemon.POSIXErrorText
import struct CmuxNextDaemon.UnixSocketAddress
import Darwin
import Foundation
import CmuxNextCompat

/// A bounded client for another local cmux control socket.
///
/// Peer calls are deliberately kept in the control package so the App's
/// transfer action uses the same JSON-lines protocol as the CLI. The client
/// only accepts a single response line and sets socket deadlines before any
/// blocking I/O; a stale build can therefore never hold the App's main actor.
public struct ControlPeerClient {
    public init() {}
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case socket(String)
        case timeout
        case responseTooLarge
        case invalidResponse
        /// The peer answered with a plain `ERROR:` line and closed, as a
        /// classic build does for a client its socket mode does not admit.
        case refused(String)
        case peer(ControlError)

        public var description: String {
            switch self {
            case .socket(let message): "peer socket: \(message)"
            case .timeout: "peer control request timed out"
            case .responseTooLarge: "peer control response was too large"
            case .invalidResponse: "peer control response was invalid"
            case .refused(let message): "peer refused the connection: \(message)"
            case .peer(let error): "peer control request failed: \(error.message)"
            }
        }
    }

    /// Sends one v2 control request to `path` and returns its result.
    public static func request(path: String, method: String, params: [String: JSONValue] = [:],
                               timeout: Duration = .seconds(2)) async throws -> JSONValue {
        let seconds = max(1, timeout.wholeMilliseconds)
        return try await Task.detached(priority: .utility) {
            try exchange(path: path, method: method, params: params, timeoutMilliseconds: seconds)
        }.value
    }

    private static func exchange(path: String, method: String, params: [String: JSONValue],
                                timeoutMilliseconds: Int) throws -> JSONValue {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(POSIXErrorText(errno).description) }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: timeoutMilliseconds / 1_000,
                              tv_usec: Int32(clamping: (timeoutMilliseconds % 1_000) * 1_000))
        var noSigPipe: Int32 = 1 // a peer that hangs up fails the write with EPIPE instead of signalling
        // SAFETY: each setsockopt reads the size it is given from a local of exactly that type (`noSigPipe`, an
        // Int32; `timeout`, a timeval), live for the call.
        guard unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              unsafe setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              unsafe setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure.socket(POSIXErrorText(errno).description)
        }
        guard let address = UnixSocketAddress(path: path) else { throw Failure.socket("path too long") }
        guard address.connect(descriptor) == 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw Failure.timeout }
            throw Failure.socket(POSIXErrorText(errno).description)
        }

        let request = JSONValue.object([
            "id": .number(1),
            "method": .string(method),
            "params": .object(params),
        ])
        var outbound = Data(request.compactText.utf8)
        outbound.append(0x0A)
        try writeAll(outbound, descriptor: descriptor)
        var inbound = Data()
        var byte = [UInt8](repeating: 0, count: 16 * 1024)
        while inbound.count <= 4 * 1024 * 1024 {
            // SAFETY: read writes at most byte.count bytes into the array's own storage, lent for the call.
            let count = unsafe read(descriptor, &byte, byte.count)
            if count > 0 {
                inbound.append(contentsOf: byte.prefix(count))
                if let newline = inbound.firstIndex(of: 0x0A) {
                    let line = inbound.prefix(upTo: newline)
                    if line.starts(with: Data("ERROR:".utf8)) { throw Failure.refused(String(decoding: line, as: UTF8.self)) }
                    guard let response = try? JSONValue.parse(Data(line)),
                          let object = response.objectValue else { throw Failure.invalidResponse }
                    if object["ok"]?.boolValue == true { return object["result"] ?? .null }
                    guard let errorObject = object["error"]?.objectValue,
                          let code = errorObject["code"]?.stringValue,
                          let message = errorObject["message"]?.stringValue else { throw Failure.invalidResponse }
                    throw Failure.peer(ControlError(code: code, message: message, data: errorObject["data"]))
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw Failure.timeout }
            throw Failure.invalidResponse
        }
        throw Failure.responseTooLarge
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        // SAFETY: `bytes` is Data's contiguous storage, valid only inside this closure, which never lets a pointer out.
        let failure: Int32? = unsafe data.withUnsafeBytes { bytes -> Int32? in
            guard let base = unsafe bytes.baseAddress else { return nil }
            while unsafe offset < bytes.count {
                // SAFETY: 0 <= offset < bytes.count, so the write covers the bytes.count - offset bytes left, from
                // base + offset to the buffer's end.
                let count = unsafe blockingWrite(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                return count < 0 ? errno : EIO
            }
            return nil
        }
        guard let failure else { return }
        if failure == EAGAIN || failure == EWOULDBLOCK || failure == ETIMEDOUT { throw Failure.timeout }
        throw Failure.socket(POSIXErrorText(failure).description)
    }
}

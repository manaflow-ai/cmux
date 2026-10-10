public import CmuxNextSettings
import Darwin
import Foundation

/// A bounded client for another local cmux control socket.
///
/// Peer calls are deliberately kept in the control package so the App's
/// transfer action uses the same JSON-lines protocol as the CLI. The client
/// only accepts a single response line and sets socket deadlines before any
/// blocking I/O; a stale build can therefore never hold the App's main actor.
public enum ControlPeerClient {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case socket(String)
        case timeout
        case responseTooLarge
        case invalidResponse
        case peer(ControlError)

        public var description: String {
            switch self {
            case .socket(let message): "peer socket: \(message)"
            case .timeout: "peer control request timed out"
            case .responseTooLarge: "peer control response was too large"
            case .invalidResponse: "peer control response was invalid"
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
        guard descriptor >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: timeoutMilliseconds / 1_000,
                              tv_usec: Int32((timeoutMilliseconds % 1_000) * 1_000))
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure.socket(String(cString: strerror(errno)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.socket("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.utf8)
            bytes[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw Failure.timeout }
            throw Failure.socket(String(cString: strerror(errno)))
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
            let count = read(descriptor, &byte, byte.count)
            if count > 0 {
                inbound.append(byte, count: count)
                if let newline = inbound.firstIndex(of: 0x0A) {
                    let line = inbound.prefix(upTo: newline)
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
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw Failure.timeout }
                throw Failure.socket(String(cString: strerror(errno)))
            }
        }
    }
}

public import Foundation

/// A stable, file-scope identity for Unix-domain socket connection failures.
///
/// Keep the socket path in the rendered description for CLI diagnostics, but
/// exclude it from Sentry grouping so tagged sockets share one errno group.
public struct CLISocketConnectError: Error, CustomNSError, CustomStringConvertible, Sendable {
    public static let errorDomain = "com.cmux.cli.socket-connect"

    public let path: String
    public let errnoCode: Int32

    public init(path: String, errnoCode: Int32) {
        self.path = path
        self.errnoCode = errnoCode
    }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = strerror_r(errnoCode, &buffer, buffer.count)
        let message: String
        if result == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            message = String(decoding: bytes, as: UTF8.self)
        } else {
            message = "Unknown error: \(errnoCode)"
        }
        return "Failed to connect to socket at \(path) (\(message), errno \(errnoCode))"
    }

    public var errorCode: Int {
        Int(errnoCode)
    }

    public var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: description,
            NSDebugDescriptionErrorKey: description,
        ]
    }

    public var sentryFingerprint: [String] {
        ["cmux-cli", "socket-connect", "errno-\(errnoCode)"]
    }
}

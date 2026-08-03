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
        "Failed to connect to socket at \(path) (\(String(cString: strerror(errnoCode))), errno \(errnoCode))"
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

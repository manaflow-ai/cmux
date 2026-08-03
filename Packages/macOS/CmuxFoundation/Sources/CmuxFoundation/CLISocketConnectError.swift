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
            message = Self.decodeSystemErrorMessage(bytes: bytes, errnoCode: errnoCode)
        } else {
            message = Self.localizedUnknownSystemError(errnoCode: errnoCode)
        }

        let format = String(
            localized: "cli.socket.error.connectFailed",
            defaultValue: "Failed to connect to socket at %1$@ (%2$@, errno %3$lld)"
        )
        return String(format: format, locale: Locale.current, path, message, Int64(errnoCode))
    }

    static func decodeSystemErrorMessage(bytes: [UInt8], errnoCode: Int32) -> String {
        String(bytes: bytes, encoding: .utf8)
            ?? localizedUnknownSystemError(errnoCode: errnoCode)
    }

    private static func localizedUnknownSystemError(errnoCode: Int32) -> String {
        let format = String(
            localized: "cli.socket.error.unknownSystemError",
            defaultValue: "Unknown error: %lld"
        )
        return String(format: format, locale: Locale.current, Int64(errnoCode))
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

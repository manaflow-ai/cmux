public import Foundation

/// A stable, file-scope identity for Unix-domain socket connection failures.
///
/// User-visible text stays product-level while structured telemetry retains the
/// connection details needed to diagnose failures and group tagged sockets.
public struct CLISocketConnectError: Error, CustomNSError, CustomStringConvertible, Sendable {
    public static let errorDomain = "com.cmux.cli.socket-connect"

    public let path: String
    public let errnoCode: Int32

    public init(path: String, errnoCode: Int32) {
        self.path = path
        self.errnoCode = errnoCode
    }

    public var description: String {
        String(
            localized: "cli.socket.error.connectFailed",
            defaultValue: "Failed to connect to cmux."
        )
    }

    /// Structured diagnostics for internal telemetry. Never render these
    /// fields directly in user-visible CLI output.
    public var telemetryContext: [String: String] {
        [
            "socket_path": path,
            "errno": String(errnoCode),
            "system_error": systemErrorMessage,
        ]
    }

    private var systemErrorMessage: String {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = strerror_r(errnoCode, &buffer, buffer.count)
        if result == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return Self.decodeSystemErrorMessage(bytes: bytes, errnoCode: errnoCode)
        }
        return Self.localizedUnknownSystemError(errnoCode: errnoCode)
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

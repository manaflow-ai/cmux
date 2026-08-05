public import Foundation

/// A stable, file-scope identity for Unix-domain socket connection failures.
///
/// User-visible text stays product-level while structured telemetry retains the
/// connection details needed to diagnose failures and group tagged sockets.
public struct CLISocketConnectError: Error, CustomNSError, CustomStringConvertible, Sendable {
    /// Stable Cocoa error domain used for Sentry grouping and NSError bridging.
    public static let errorDomain = "com.cmux.cli.socket-connect"

    /// Unix-domain socket path supplied to `connect(2)`.
    public let path: String
    /// POSIX error code produced by the failed connection attempt.
    public let errnoCode: Int32

    /// Creates a typed connection failure.
    ///
    /// - Parameters:
    ///   - path: Unix-domain socket path supplied to `connect(2)`.
    ///   - errnoCode: POSIX error code returned by the failed attempt.
    public init(path: String, errnoCode: Int32) {
        self.path = path
        self.errnoCode = errnoCode
    }

    /// Localized product-level message safe to print to the user.
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
            return decodeSystemErrorMessage(bytes: bytes, errnoCode: errnoCode)
        }
        return localizedUnknownSystemError(errnoCode: errnoCode)
    }

    /// POSIX error code exposed through `CustomNSError`.
    public var errorCode: Int {
        Int(errnoCode)
    }

    /// User-safe NSError metadata that omits the socket path and system detail.
    public var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: description,
            NSDebugDescriptionErrorKey: description,
        ]
    }

    /// Stable Sentry grouping key that excludes runtime symbol addresses.
    public var sentryFingerprint: [String] {
        ["cmux-cli", "socket-connect", "errno-\(errnoCode)"]
    }
}

func decodeSystemErrorMessage(bytes: [UInt8], errnoCode: Int32) -> String {
    String(bytes: bytes, encoding: .utf8)
        ?? localizedUnknownSystemError(errnoCode: errnoCode)
}

private func localizedUnknownSystemError(errnoCode: Int32) -> String {
    let format = String(
        localized: "cli.socket.error.unknownSystemError",
        defaultValue: "Unknown error: %lld"
    )
    return String(format: format, locale: Locale.current, Int64(errnoCode))
}

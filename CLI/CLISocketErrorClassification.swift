import Darwin
import Foundation

/// Decides whether a CLI socket error is an *expected* "the cmux app/socket
/// peer just is not reachable" condition that must never be reported to Sentry.
///
/// The `cmux` CLI runs on essentially every shell prompt and agent hook. When
/// the app is not running (or a peer closes mid-write), the CLI fails to reach
/// the socket and that is the normal, uninteresting outcome. Capturing each of
/// those as a Sentry event produced tens of millions of events per month, which
/// exhausted the `cmuxterm-macos` project quota and made real crashes invisible.
/// Routing those expected errors through this classifier keeps them out of
/// telemetry (and off the synchronous `SentrySDK.flush` that stalled the
/// prompt), while anything unrecognized still reports normally.
enum CLISocketErrorClassification {
    /// `errno` values that mean the peer is simply unavailable, not that
    /// something is broken.
    static let expectedTransportErrnos: Set<Int32> = [
        EPIPE,          // 32  broken pipe (app closed mid-write)
        ENOENT,         // 2   socket path does not exist (app not running)
        ECONNREFUSED,   // 61  nobody listening on the socket
        ECONNRESET,     // 54  peer reset the connection
        ENOTCONN,       // 57  not connected
        ETIMEDOUT,      // 60  connect/read timed out
        EAGAIN,         // 35  would block / temporary
        EADDRNOTAVAIL   // 47  address not available
    ]

    /// Benign transport conditions the CLI raises without an embedded `errno`.
    /// Matched as substrings so the wording at the throw site stays the single
    /// source of truth.
    static let expectedTransportMessageFragments: [String] = [
        "Socket not found at",
        "Path exists at",
        "is not owned by the current user",
        "Not connected",
        "Socket closed before reply",
        "Socket closed before complete reply",
        "Socket read error",
        "Command timed out",
        "Failed to connect to socket at",
        "Failed to connect to relay at",
        "Failed to create socket",
        "Failed to create relay socket"
    ]

    /// Returns `true` when `error` is an expected socket-unavailable /
    /// peer-closed condition that should be suppressed from telemetry.
    ///
    /// Returns `false` for anything unrecognized so genuinely unexpected errors
    /// (and process crashes, which never flow through this path) still report.
    static func isExpectedTransportError(_ error: Error) -> Bool {
        let text = String(describing: error)
        if let code = embeddedErrno(in: text), expectedTransportErrnos.contains(code) {
            return true
        }
        return expectedTransportMessageFragments.contains { text.contains($0) }
    }

    /// Extracts the integer N from cmux's own `errno N` suffix (e.g.
    /// "Failed to write to socket (Broken pipe, errno 32)"). That token is
    /// formatted by cmux, not the OS, so it is stable and locale-independent.
    /// Returns `nil` when no such token is present.
    static func embeddedErrno(in text: String) -> Int32? {
        guard let range = text.range(of: "errno ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int32(digits)
    }
}

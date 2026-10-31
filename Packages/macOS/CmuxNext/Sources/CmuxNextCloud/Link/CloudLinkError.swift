public import Foundation

/// Why a Cloud link has no socket. The App shows the localized text
/// (`CloudStrings.errorText`); ``description`` is the same in English for
/// logs and any caller that prints the error, never a Swift dump.
public enum CloudLinkError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The link went down or its connection ended. v1 does not reconnect by
    /// itself: the user connects again.
    case disconnected(reason: String)
    /// The backend revoked the link.
    case revoked(reason: String)
    /// This Mac's connection helper (`cmux link`) is not running or did not
    /// answer (`cmux.cloud.link_unavailable`).
    case helperNotRunning(reason: String)
    /// The answer named a socket that is not an owner-only socket of this user.
    case unsafeSocket(String)
    /// Other users can enter the link socket's directory (`parent` false) or
    /// change one of its parents (`parent` true) at `path`, so the app does
    /// not connect: `chmod` fixes it.
    case openDirectory(path: String, parent: Bool)
    /// The answer is not a carrier of the asked machine, or names no socket.
    case invalidAnswer(String)
    /// The machine's carrier is in `state` (the Cloud server's word), not `up`.
    case notUp(state: String)
    /// The op failed with the app server's error code.
    case failed(code: String, message: String)
    /// This resolver is not available yet.
    case unsupported

    public var description: String {
        switch self {
        case .disconnected(let reason): "Disconnected from the Cloud machine\(Self.because(reason)). Click Connect to connect again."
        case .revoked(let reason): "Access to this Cloud machine was revoked\(Self.because(reason)). Click Connect to connect again."
        case .helperNotRunning(let reason):
            "The Cloud connection helper is not running on this Mac\(Self.because(reason)). Click Connect to start it."
        case .openDirectory(let path, let parent):
            "cmux didn't connect because other users can open \(path). Run `\(Self.chmodFix(path: path, parent: parent))`, then click Connect."
        case .unsafeSocket(let detail), .invalidAnswer(let detail):
            "cmux didn't connect: the Cloud app's answer for this machine failed a safety check (\(detail)). Click Connect to try again."
        case .notUp(let state): "The machine's connection isn't ready yet (\(state)). Click Connect to try again."
        case .failed(let code, let message): "Could not connect to the Cloud machine (\(message.isEmpty ? code : message)). Click Connect to try again."
        case .unsupported: "This version of cmux can't connect to the Cloud machine this way. Update cmux, then click Connect."
        }
    }

    public var errorDescription: String? { description }

    /// The command that closes an ``openDirectory(path:parent:)``: the socket
    /// folder to owner-only, a parent to not writable by others.
    public static func chmodFix(path: String, parent: Bool) -> String {
        "chmod \(parent ? "go-w" : "700") \(shellQuoted(path))"
    }

    /// `path` as one shell word: bare when it is only safe characters, else in single quotes.
    static func shellQuoted(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        if !path.isEmpty, path.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// " (reason)", or nothing for an empty reason.
    private static func because(_ reason: String) -> String { reason.isEmpty ? "" : " (\(reason))" }
}

/// An app server op failure, as the daemon answered it (`error_code`). It
/// reads as the server's message, else its code.
public struct CloudAppOpError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message.isEmpty ? code : message }
    public var errorDescription: String? { description }
}

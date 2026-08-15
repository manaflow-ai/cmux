public import Foundation

/// A localized failure produced by the Chrome DevTools Protocol transport.
public enum CDPError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// A CDP URL or port is malformed or violates the loopback-only policy.
    case invalidEndpoint
    /// The requested loopback port is already bound.
    case portUnavailable(Int)
    /// No page-scoped CDP connection is active.
    case notConnected
    /// The transport closed while an operation was active.
    case disconnected(String)
    /// Chromium returned a value that violates the expected protocol shape.
    case protocolError(String)
    /// Chromium rejected a validly encoded CDP command.
    case commandFailed(String)
    /// A websocket payload could not be decoded as a CDP message.
    case malformedMessage

    /// Human-readable localized failure text.
    public var description: String {
        switch self {
        case .invalidEndpoint:
            return String(
                localized: "browser.chromium.cdp.invalidEndpoint",
                defaultValue: "Invalid CDP endpoint",
                bundle: .module
            )
        case .portUnavailable(let port):
            let format = String(
                localized: "browser.chromium.cdp.portUnavailable",
                defaultValue: "CDP port %lld is unavailable on loopback",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, Int64(port))
        case .notConnected:
            return String(
                localized: "browser.chromium.cdp.notConnected",
                defaultValue: "CDP is not connected",
                bundle: .module
            )
        case .disconnected(let message):
            let format = String(
                localized: "browser.chromium.cdp.disconnected",
                defaultValue: "CDP disconnected: %@",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, message)
        case .protocolError(let message):
            let format = String(
                localized: "browser.chromium.cdp.protocolError",
                defaultValue: "CDP protocol error: %@",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, message)
        case .commandFailed(let message):
            return message
        case .malformedMessage:
            return String(
                localized: "browser.chromium.cdp.malformedMessage",
                defaultValue: "Malformed CDP message",
                bundle: .module
            )
        }
    }

    /// The localized description surfaced through Foundation error APIs.
    public var errorDescription: String? { description }
}

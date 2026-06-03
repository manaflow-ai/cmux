import Foundation

/// An error raised by the authenticated mobile route transport.
public enum MobileRouteClientError: Error, Equatable, Sendable {
    /// The server returned a response that was not an `HTTPURLResponse`.
    case invalidResponse

    /// The server returned a non-2xx status code, with an optional parsed error message.
    case httpError(Int, String?)
}

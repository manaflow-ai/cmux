import Foundation

/// The Stack token pair cmux NIGHTLY hands to another local cmux build over its control socket
/// (``SessionHandoffResponder``, ``SessionHandoffClient``).
///
/// Its descriptions never show the tokens, so string interpolation, `dump` or a crash report's
/// variable print cannot leak them.
public struct SessionHandoffPair: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The access token, when the sender had one.
    public let accessToken: String?
    /// The refresh token: the session itself.
    public let refreshToken: String

    /// Nil unless `refreshToken` is non-empty: a pair without one is no session.
    public init?(accessToken: String?, refreshToken: String?) {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        self.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        self.refreshToken = refreshToken
    }

    public var description: String { "SessionHandoffPair(hasAccess: \(accessToken != nil), tokens redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["hasAccess": accessToken != nil], displayStyle: .struct) }
}

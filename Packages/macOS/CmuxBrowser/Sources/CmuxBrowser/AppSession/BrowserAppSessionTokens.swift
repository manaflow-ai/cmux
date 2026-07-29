/// Native Stack credentials used to establish a browser-only web session.
public struct BrowserAppSessionTokens: Equatable, Sendable {
    /// The refresh token used to establish the browser session.
    public let refreshToken: String

    /// Creates the credentials for a native-to-web session handoff.
    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

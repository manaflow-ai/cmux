/// Native Stack credentials used to establish a browser-only web session.
public struct BrowserAppSessionTokens: Equatable, Sendable {
    /// The access token paired with the refresh token below.
    public let accessToken: String
    /// The refresh token used to establish the browser session.
    public let refreshToken: String

    /// Creates the credentials for a native-to-web session handoff.
    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

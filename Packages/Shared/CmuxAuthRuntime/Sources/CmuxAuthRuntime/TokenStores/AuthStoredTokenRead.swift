/// Stored credentials and the availability of the read that produced them.
///
/// Availability belongs to this value, so another caller cannot consume a
/// temporary read failure before the session owner decides whether to clear.
public struct AuthStoredTokenRead: Sendable {
    /// The stored access token, if one was readable.
    public let accessToken: String?
    /// The stored refresh token, if one was readable.
    public let refreshToken: String?
    /// Whether empty credentials are a definitive answer from storage.
    public let isAvailable: Bool

    /// Creates a read result without separating credentials from read status.
    /// - Parameters:
    ///   - accessToken: The access token returned by this read.
    ///   - refreshToken: The refresh token returned by this read.
    ///   - isAvailable: Whether this read completed without a temporary storage failure.
    public init(accessToken: String?, refreshToken: String?, isAvailable: Bool) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.isAvailable = isAvailable
    }
}

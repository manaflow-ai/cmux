/// The typed result payload for `auth.sign_in_url`.
public struct AuthSocketSignInURLPayload: Sendable, Equatable {
    /// The hosted browser sign-in URL, when the sign-in flow is attached.
    public let url: String?

    /// Creates a sign-in URL payload.
    ///
    /// - Parameter url: The hosted browser sign-in URL, when available.
    public init(url: String?) {
        self.url = url
    }
}

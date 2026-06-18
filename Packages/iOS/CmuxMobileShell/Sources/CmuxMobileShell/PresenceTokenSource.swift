/// Supplies the Stack access token for presence requests, mirroring
/// ``DeviceRegistryService/TokenSource``: tokens arrive through an injected
/// Sendable closure so the presence client needs no dependency on the auth
/// package.
public struct PresenceTokenSource: Sendable {
    /// Returns the current Stack access token, or nil when there is no
    /// session.
    public var accessToken: @Sendable () async -> String?

    /// Creates a token source backed by the given closure.
    public init(accessToken: @escaping @Sendable () async -> String?) {
        self.accessToken = accessToken
    }
}

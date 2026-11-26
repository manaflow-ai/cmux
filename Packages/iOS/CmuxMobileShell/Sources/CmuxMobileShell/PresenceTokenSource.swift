/// Supplies the Stack access token for presence requests, mirroring
/// ``DeviceRegistryService/TokenSource``: tokens arrive through an injected
/// Sendable closure so the presence client needs no dependency on the auth
/// package.
public struct PresenceTokenSource: Sendable {
    /// Returns the current Stack access token, or nil when there is no
    /// session.
    public var accessToken: @Sendable () async -> String?
    /// Returns the current Stack user id, or nil when there is no session.
    public var currentUserID: @Sendable () async -> String?

    /// Creates a token source backed by the given closure.
    public init(
        accessToken: @escaping @Sendable () async -> String?,
        currentUserID: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.accessToken = accessToken
        self.currentUserID = currentUserID
    }

    /// Read a token only when auth still belongs to the captured account.
    public func accessToken(expectedUserID: String?) async -> String? {
        guard let expectedUserID else { return await accessToken() }
        guard await currentUserID() == expectedUserID else { return nil }
        let token = await accessToken()
        guard token != nil, await currentUserID() == expectedUserID else { return nil }
        return token
    }
}

/// Generation-scoped ownership for first-connection registry requests.
public struct MobileFirstConnectionDiscoveryScope: Equatable, Sendable {
    /// One request generation captured before an asynchronous registry read.
    public struct Token: Equatable, Sendable {
        fileprivate let scopeID: String
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeToken: Token?

    /// Creates an inactive discovery scope.
    public init() {}

    /// Activates a new generation for the account/team scope.
    @discardableResult
    public mutating func activate(_ scopeID: String) -> Token {
        generation &+= 1
        let token = Token(scopeID: scopeID, generation: generation)
        activeToken = token
        return token
    }

    /// Invalidates every request captured from the current generation.
    public mutating func invalidate() {
        activeToken = nil
    }

    /// Returns the active request token for this account/team scope.
    public func token(for scopeID: String) -> Token? {
        guard activeToken?.scopeID == scopeID else { return nil }
        return activeToken
    }

    /// Whether a captured request still owns the current presentation state.
    public func isCurrent(_ token: Token) -> Bool {
        activeToken == token
    }

    /// Whether this account/team scope is currently mounted.
    public func isActive(_ scopeID: String) -> Bool {
        activeToken?.scopeID == scopeID
    }
}

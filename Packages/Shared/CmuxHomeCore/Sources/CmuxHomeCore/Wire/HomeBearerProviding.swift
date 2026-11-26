/// Supplies the Stack access token for ``HomeWireAuth/stack(_:)``.
public protocol HomeBearerProviding: Sendable {
    /// The current access token; `forceRefresh` asks for a new one (after a
    /// 401 or a 4401 close).
    func accessToken(forceRefresh: Bool) async throws -> String
}

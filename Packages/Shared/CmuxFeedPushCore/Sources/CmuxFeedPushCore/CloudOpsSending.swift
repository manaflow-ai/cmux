/// Sends typed ops to the API Worker (`POST /v1/ops`) as an install of the
/// signed-in user. Implementations refuse redirects, so the bearer never
/// reaches another origin.
public protocol CloudOpsSending: Sendable {
    /// Sends as the install of `user` (nil: the current user).
    func send(_ op: CloudOp, as user: String?) async throws
}

extension CloudOpsSending {
    public func send(_ op: CloudOp) async throws { try await send(op, as: nil) }
}

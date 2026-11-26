import Foundation

/// The Cloud service's Auto chat routes (`/v1/auto-sessions`, `plans/cmux-next/auto-mode/DESIGN.md`)
/// as the signed-in account: the same bearer, refresh and build space as this account's other
/// Cloud calls. Nothing goes through a Mac.
extension AccountCloud {
    /// One answer of the Auto chat routes: its status and its body, as they came.
    public struct AutoChatReply: Sendable {
        public var status: Int
        public var body: Data
    }

    /// The only paths ``autoChats(_:_:body:timeout:)`` sends.
    static let autoChatRoot = "/v1/auto-sessions"

    /// `method path` to the Auto chat routes. A path outside them is refused here and never sent:
    /// what asks (the app's Rust client) reaches no other route with this account's bearer.
    /// `timeout`: how long the request may take; the service holds a chat's wait for up to 25 s.
    public func autoChats(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) async throws -> AutoChatReply {
        let root = Self.autoChatRoot
        // A `..` part, written plainly or percent-encoded, would leave the routes once the URL is resolved.
        guard path == root || path.hasPrefix(root + "/") || path.hasPrefix(root + "?"),
              let plain = path.removingPercentEncoding, !plain.contains("..") else { throw Failure.badReply }
        do {
            let reply = try await http.send(method, path, body: body, timeout: timeout)
            return AutoChatReply(status: reply.status, body: reply.body)
        } catch {
            throw Self.cancellation(error) ?? Failure.unreachable
        }
    }
}

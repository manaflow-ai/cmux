#if os(iOS)
import Foundation

/// One inline notification reply handed to the server-side inbox.
public struct RelayedReply: Equatable, Sendable {
    /// Stable idempotency key: the retry ladder re-sends the same id, so the
    /// server can never park one reply twice.
    public let replyId: String
    /// The Mac claimed by the originating push; the inbox routes by it.
    public let macDeviceId: String
    /// The workspace claim from the push, if it carried one; the Mac
    /// re-resolves the live owner either way.
    public let workspaceId: String?
    /// The exact terminal claim from the push.
    public let surfaceId: String
    /// The user's reply text, without the submit return.
    public let text: String

    /// Creates a relayed reply from the parked reply's claims.
    public init(
        replyId: String,
        macDeviceId: String,
        workspaceId: String?,
        surfaceId: String,
        text: String
    ) {
        self.replyId = replyId
        self.macDeviceId = macDeviceId
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.text = text
    }
}

/// Seam over the presence worker's phone reply inbox
/// (`workers/presence/src/replies.ts`).
///
/// This is what makes inline replies survivable from a backgrounded app: the
/// phone's whole job shrinks to ONE authenticated HTTPS POST — no transport
/// dial, no pairing, no live Mac — and the Mac fetches and types the reply on
/// its own schedule. The production conformance is ``SystemReplyRelayClient``;
/// tests inject a fake to script acceptance and failure.
public protocol ReplyRelaying: Sendable {
    /// Parks the reply server-side. Returns `true` when the service accepted
    /// (including the idempotent duplicate case).
    func relay(_ reply: RelayedReply) async -> Bool
}

/// A relay that always declines, for previews and coordinators constructed
/// without a service origin; the reply then stays parked and the failure
/// notice reports it, which is the pre-relay behavior.
public struct NoopReplyRelay: ReplyRelaying {
    public init() {}
    public func relay(_ reply: RelayedReply) async -> Bool { false }
}

/// Production ``ReplyRelaying`` backed by `POST /v1/replies` on the presence
/// worker, authenticated with the caller's Stack access token.
public struct SystemReplyRelayClient: ReplyRelaying {
    private let serviceBaseURL: URL?
    private let accessToken: @Sendable () async -> String?
    private let session: URLSession

    /// - Parameters:
    ///   - serviceBaseURL: The presence worker origin (the same one the
    ///     connectivity subscriber uses). `nil` disables the relay.
    ///   - accessToken: Live Stack access-token provider from the auth runtime.
    public init(
        serviceBaseURL: URL?,
        accessToken: @escaping @Sendable () async -> String?,
        session: URLSession = .shared
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.accessToken = accessToken
        self.session = session
    }

    public func relay(_ reply: RelayedReply) async -> Bool {
        guard let serviceBaseURL,
              var comps = URLComponents(
                  url: serviceBaseURL,
                  resolvingAgainstBaseURL: false
              ) else { return false }
        guard let token = await accessToken(), !token.isEmpty else { return false }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/replies"
        guard let url = comps.url else { return false }
        var body: [String: Any] = [
            "replyId": reply.replyId,
            "macDeviceId": reply.macDeviceId,
            "surfaceId": reply.surfaceId,
            "text": reply.text,
        ]
        if let workspaceId = reply.workspaceId, !workspaceId.isEmpty {
            body["workspaceId"] = workspaceId
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Comfortably inside the reply lane's background window, long enough
        // for a cold TLS handshake on cellular.
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
#endif

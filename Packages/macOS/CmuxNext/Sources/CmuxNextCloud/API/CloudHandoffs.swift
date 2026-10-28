public import Foundation

/// The person's hand-offs (cloud work mode; cmux#26578, `backend/apps/api/src/handoffs/`): a chat
/// handed to a Cloud machine, which reports `running`, `needs-you`, `done` or `failed` and a summary.
/// The owner reads them on the backend API (`ownerAPIBaseURL`), not on cmux.com.
extension CloudOwnerAPIClient {
    /// The longest the store holds one wait (`MAX_WAIT_MS`).
    public static let handoffWaitLimitMs = 25_000

    /// `GET /v1/handoffs/:id/wait?after=&timeoutMs=`: `{handoff}` once its version passes `after`
    /// (nil: at once), or at the deadline (25 s at most). Answers the body as sent.
    public func handoffWait(_ id: String, after: Int?, timeoutMs: Int = handoffWaitLimitMs) async throws -> Data {
        guard Self.isHandoffID(id) else { throw CloudAPIError.transport("not a hand-off id") }
        let held = max(0, min(timeoutMs, Self.handoffWaitLimitMs))
        return try await get("/v1/handoffs/\(id)/wait", query: [("after", max(0, after ?? 0)), ("timeoutMs", held)],
                             timeout: .milliseconds(held) + .seconds(15))
    }

    /// `GET /v1/handoffs?limit=`: the person's newest hand-offs (the first page).
    public func handoffs(limit: Int = 100) async throws -> [CloudHandoff] {
        struct Page: Decodable { var handoffs: [CloudHandoff] }
        let data = try await get("/v1/handoffs", query: [("limit", max(1, min(limit, 100)))], timeout: .seconds(30))
        do { return try JSONDecoder().decode(Page.self, from: data).handoffs } catch { throw CloudAPIError.decoding("/v1/handoffs: \(error)") }
    }

    /// The store's ids (`ho_` and 20 hex digits), the only path part that varies.
    public static func isHandoffID(_ id: String) -> Bool { id.range(of: #"^ho_[0-9a-f]{20}$"#, options: .regularExpression) != nil }
}

/// One hand-off as the owner's list shows it.
public nonisolated struct CloudHandoff: Decodable, Hashable, Sendable {
    public var id: String
    /// The agent chat that was handed off: what a click opens.
    public var sessionId: String
    /// `starting`, `running`, `needs-you`, `done`, `failed` or `cancelled`.
    public var status: String
    public var summary: String?
    /// Milliseconds since 1970.
    public var createdAt: Double
    public var version: Int?

    public init(id: String, sessionId: String, status: String, summary: String?, createdAt: Double, version: Int?) {
        (self.id, self.sessionId, self.status, self.summary, self.createdAt, self.version) = (id, sessionId, status, summary, createdAt, version)
    }

    /// It can still change (not done, failed or cancelled).
    public var isOpen: Bool { !["done", "failed", "cancelled"].contains(status) }
}

extension SandboxRunFollower.Source {
    /// Where the followed hand-offs are kept between launches.
    public static let handoffsKey = "cmux.next.handoffs.following"

    /// Hand-offs: each wait passes the last version seen. `done` and `failed` are told, and each
    /// stop at `needs-you`; `cancelled` never is (only its owner cancels one). A hand-off may run
    /// for a long time: it is given up after three days.
    public static func handoffs(wait: @escaping @Sendable (_ id: String, _ after: Int?) async throws -> Data) -> Self {
        Self(wait: { id, _, cursor in try await wait(id, cursor) }, read: readHandoff, defaultsKey: handoffsKey,
             maximumAge: 3 * 86_400, tells: [.succeeded, .failed, .needsYou], path: "/v1/handoffs")
    }

    /// One wait's `{handoff}`. A body of another shape, or a status the store has not, is unreadable.
    public static func readHandoff(_ data: Data) -> CloudTaskRead {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let handoff = object["handoff"] as? [String: Any], let status = handoff["status"] as? String,
              let version = handoff["version"] as? Int else { return .unreadable }
        switch status {
        case "starting", "running": return .progress(cursor: version)
        case "needs-you": return .needsYou(cursor: version, data)
        case "done": return .ended(.succeeded, data)
        case "failed": return .ended(.failed, data)
        case "cancelled": return .ended(.cancelled, data)
        default: return .unreadable
        }
    }
}

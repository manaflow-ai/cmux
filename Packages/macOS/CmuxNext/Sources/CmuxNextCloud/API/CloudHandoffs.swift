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
    /// The turn (from 1, only goes up): a follow-up in the same chat opens the next on the same id.
    public var turn: Int?
    /// `open` or `closed`: only a closed hand-off changes no more.
    public var state: String?

    public init(id: String, sessionId: String, status: String, summary: String?, createdAt: Double, version: Int?,
                turn: Int? = nil, state: String? = nil) {
        (self.id, self.sessionId, self.status, self.summary, self.createdAt) = (id, sessionId, status, summary, createdAt)
        (self.version, self.turn, self.state) = (version, turn, state)
    }

    /// It can still change: not closed (a store from before turns: not done, failed or cancelled).
    public var isOpen: Bool { state.map { $0 != "closed" } ?? !Self.turnEnds.contains(status) }

    /// What the person is told about this turn's status, if anything: done, failed and needs-you,
    /// once per turn and status. Never cancelled, starting or running.
    public static func notice(status: String, turn: Int?) -> CloudTaskNotice? {
        let outcome: SandboxRunEnd.Outcome? = switch status {
        case "done": .succeeded
        case "failed": .failed
        case "needs-you": .needsYou
        default: nil
        }
        return outcome.map { CloudTaskNotice(key: "\(turn ?? 1):\(status)", outcome: $0) }
    }

    static let statuses: Set<String> = ["starting", "running", "needs-you", "done", "failed", "cancelled"]
    /// The statuses that end a turn (and, before turns, the hand-off).
    static let turnEnds: Set<String> = ["done", "failed", "cancelled"]
}

extension SandboxRunFollower.Source {
    /// Where the followed hand-offs are kept between launches.
    public static let handoffsKey = "cmux.next.handoffs.following"

    /// Hand-offs: a hand-off lasts the whole session and counts turns (hq#4706). Each wait passes
    /// the last version seen; each turn's done, failed and needs-you is told once (``CloudHandoff/notice(status:turn:)``),
    /// never a cancel. The follow goes on after a turn ends and stops when the hand-off is closed,
    /// or when it has not changed for three days.
    public static func handoffs(wait: @escaping @Sendable (_ id: String, _ after: Int?) async throws -> Data) -> Self {
        Self(wait: { id, _, cursor in try await wait(id, cursor) }, read: readHandoff, defaultsKey: handoffsKey,
             maximumAge: 3 * 86_400, tells: [], path: "/v1/handoffs")
    }

    /// One wait's `{handoff}`. A body of another shape, or a status the store has not, is unreadable.
    /// A store from before turns (no `state`) closes a hand-off with its first done, failed or cancel.
    public static func readHandoff(_ data: Data) -> CloudTaskRead {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let handoff = object["handoff"] as? [String: Any], let status = handoff["status"] as? String,
              CloudHandoff.statuses.contains(status), let version = handoff["version"] as? Int else { return .unreadable }
        let turn = handoff["turn"] as? Int
        let state = handoff["state"] as? String
        guard state == nil || state == "open" || state == "closed" else { return .unreadable }
        let notice = CloudHandoff.notice(status: status, turn: turn)
        let closed = state.map { $0 == "closed" } ?? CloudHandoff.turnEnds.contains(status)
        return closed ? .closed(notice: notice, data) : .going(cursor: version, notice: notice, data)
    }
}

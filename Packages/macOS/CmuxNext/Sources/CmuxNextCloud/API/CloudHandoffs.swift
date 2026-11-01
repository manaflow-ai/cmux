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

    /// `GET /v1/handoffs?limit=&cursor=`: the person's hand-offs, newest first, page after page
    /// (at most `pages` of 100).
    public func handoffs(pages: Int = 20) async throws -> [CloudHandoff] {
        struct Page: Decodable { var handoffs: [CloudHandoff]; var nextCursor: String? }
        var all: [CloudHandoff] = [], cursor: String?
        for _ in 0..<max(1, pages) {
            let data = try await get("/v1/handoffs", query: [("limit", 100)], cursor: cursor, timeout: .seconds(30))
            let page: Page
            do { page = try JSONDecoder().decode(Page.self, from: data) } catch { throw CloudAPIError.decoding("/v1/handoffs: \(error)") }
            all += page.handoffs
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return all
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
    /// Milliseconds since 1970 (the store sends an ISO 8601 time).
    public var createdAt: Double
    /// When it last changed (a turn begun, a status, a close), milliseconds since 1970; nil: not sent.
    public var updatedAt: Double?
    /// Not in the list (a wait's `{handoff}` has it).
    public var version: Int?
    /// The turn (from 1, only goes up): a follow-up in the same chat opens the next on the same id.
    public var turn: Int?
    /// `open` or `closed`: only a closed hand-off changes no more.
    public var state: String?

    public init(id: String, sessionId: String, status: String, summary: String?, createdAt: Double, version: Int?,
                turn: Int? = nil, state: String? = nil, updatedAt: Double? = nil) {
        (self.id, self.sessionId, self.status, self.summary, self.createdAt) = (id, sessionId, status, summary, createdAt)
        (self.version, self.turn, self.state, self.updatedAt) = (version, turn, state, updatedAt)
    }

    private enum CodingKeys: String, CodingKey { case id, sessionId, status, summary, createdAt, updatedAt, version, turn, state }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        (id, sessionId, status) = try (c.decode(String.self, forKey: .id), c.decode(String.self, forKey: .sessionId), c.decode(String.self, forKey: .status))
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try Self.millis(c, .createdAt)
        if c.contains(.updatedAt), try !c.decodeNil(forKey: .updatedAt) {
            updatedAt = try Self.millis(c, .updatedAt)
        } else {
            updatedAt = nil
        }
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        turn = try c.decodeIfPresent(Int.self, forKey: .turn)
        state = try c.decodeIfPresent(String.self, forKey: .state)
    }

    /// A time as milliseconds since 1970: the store's ISO 8601 (`toISOString()`), or a number of milliseconds.
    private static func millis(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Double {
        if let ms = try? c.decode(Double.self, forKey: key) { return ms }
        let text = try c.decode(String.self, forKey: key)
        guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not an ISO 8601 time: \(text)")
        }
        return date.timeIntervalSince1970 * 1_000
    }

    /// It can still change: not closed (a store from before turns: not done, failed or cancelled).
    public var isOpen: Bool { state.map { $0 != "closed" } ?? !Self.turnEnds.contains(status) }

    /// Its current turn runs: `starting` or `running`.
    public var isRunning: Bool { Self.turnRuns.contains(status) }

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
    /// The statuses of a turn that runs: a hand-off in one is never given up for age.
    static let turnRuns: Set<String> = ["starting", "running"]
}

extension SandboxRunFollower.Source {
    /// Where the followed hand-offs are kept between launches.
    public static let handoffsKey = "cmux.next.handoffs.following"

    /// Hand-offs: a hand-off lasts the whole session and counts turns (hq#4706). Each wait passes
    /// the last version seen; each turn's done, failed and needs-you is told once (``CloudHandoff/notice(status:turn:)``),
    /// never a cancel. The follow goes on after a turn ends and stops when the hand-off is closed,
    /// or when it has not changed for three days while no turn runs.
    public static func handoffs(wait: @escaping @Sendable (_ id: String, _ after: Int?) async throws -> Data) -> Self {
        Self(wait: { id, _, cursor in try await wait(id, cursor) }, read: readHandoff, defaultsKey: handoffsKey,
             maximumAge: 3 * 86_400, tells: [], path: "/v1/handoffs", relisted: true)
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
        return closed ? .closed(notice: notice, data) : .going(cursor: version, notice: notice, data, running: CloudHandoff.turnRuns.contains(status))
    }
}

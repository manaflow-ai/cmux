public import Foundation
import os

/// Answers one G8 approval request (`apr_…`, cx-wb5.65) as the signed-in
/// person's own session, only when it is the create the person confirmed:
///
/// 1. `integration.approval.get {request}` (session only) must name `op`,
///    be pending, and carry exactly the confirmed params;
/// 2. the open feed approve item that carries the request must be posted by
///    `system:cloud:<team>` for that op, with the same digest;
/// 3. then `feed.answer {decision: allow, scope: once}`, origin `user`.
///
/// When no open item carries it but that team's closed item does, the person
/// answered it elsewhere (``Failure/answered(request:)``, cmux#32354).
///
/// Any mismatch refuses and answers nothing. The backend accepts an
/// integration approval only from a session (domains/feed.ts), so an
/// install, an app or an agent can never answer one. Called only by
/// ``CloudMachineCreateFlow`` after the person's native confirmation.
public nonisolated struct CloudApprovalAnswer: Sendable {
    /// One POST of a JSON body to the API Worker as the signed-in person
    /// (`v1/read`, `v1/ops`); returns the reply body.
    public typealias Call = @Sendable (_ path: String, _ body: Data) async throws -> Data

    public enum Failure: Error, Equatable {
        /// No open approval item in the feed carries the request.
        case notInFeed(request: String)
        /// The request is not the create the person confirmed.
        case mismatch(request: String, reason: String)
        case refused(code: String)
        /// The person answered it elsewhere (the phone, the dashboard): the create's own team's item that
        /// carries it is closed, while the approved op still reads pending. Nothing more to answer.
        case answered(request: String)
    }

    let call: Call
    /// Whether the person's feed already shows `team`'s own item for `request` closed (the feed owner's push,
    /// cmux#32354); such a request is not looked up or answered again. Nil: none is known.
    let answered: (@Sendable (_ request: String, _ team: String) async -> Bool)?

    public init(call: @escaping Call, answered: (@Sendable (_ request: String, _ team: String) async -> Bool)? = nil) {
        (self.call, self.answered) = (call, answered)
    }
    /// The mismatch reason when no feed item of the create's team carries the request (another team's, or none).
    public static let closedItem = "feed item or team"
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.approval")

    /// Approves `request` when it holds `op` with exactly `params` (a JSON
    /// object) in `team`, the backend team the create was sent for (the
    /// install token's team, captured when the person confirmed).
    public func approve(request: String, op: String, params: Data, team: String) async throws {
        do {
            try await checkedApprove(request: request, op: op, params: params, team: team)
        } catch let failure as Failure {
            if case .mismatch(_, let reason) = failure {
                Self.logger.error("approval \(request, privacy: .public) refused: \(reason, privacy: .public) differs")
            }
            throw failure
        }
    }

    private func checkedApprove(request: String, op: String, params: Data, team: String) async throws {
        if let answered, await answered(request, team) { throw Failure.answered(request: request) }
        let read = try await post("v1/read", ["op": "integration.approval.get", "params": ["request": request]])
        let held = read["value"] as? [String: Any] ?? [:]
        guard held["op"] as? String == op else { throw Failure.mismatch(request: request, reason: "op") }
        guard held["state"] as? String == "pending" else { throw Failure.mismatch(request: request, reason: "state") }
        let confirmed = try JSONSerialization.jsonObject(with: params) as? NSDictionary
        guard let confirmed, let heldParams = held["params"] as? NSDictionary, heldParams.isEqual(confirmed) else {
            throw Failure.mismatch(request: request, reason: "params")
        }
        guard let digest = held["digest"] as? String else { throw Failure.mismatch(request: request, reason: "digest") }
        guard let item = Self.item(carrying: request, op: op, digest: digest, team: team, in: try await approveItems("open")) else {
            // No open item: answered elsewhere when this team's closed item carries it (cmux#32354); another
            // team's item, or none, is still the mismatch.
            if Self.item(carrying: request, op: op, digest: digest, team: team, in: try await approveItems("closed")) != nil {
                throw Failure.answered(request: request)
            }
            throw Failure.mismatch(request: request, reason: Self.closedItem)
        }
        let reply = try await post("v1/ops", ["op": "feed.answer", "origin": "user", "idempotency_key": "approve:\(request)",
                                              "params": ["item": item, "answer": ["decision": "allow", "scope": "once"]]])
        if reply["ok"] as? Bool == false {
            throw Failure.refused(code: (reply["error"] as? [String: Any])?["code"] as? String ?? "unknown")
        }
    }

    /// The person's integration approve items in `state` (`open`, `closed`), newest first for closed ones.
    private func approveItems(_ state: String) async throws -> [String: Any] {
        var params: [String: Any] = ["state": state, "type": "request", "kind": "approve", "poster_kind": "integration", "limit": 100]
        if state != "open" { params["order"] = "recent" }
        return try await post("v1/read", ["op": "feed.list", "params": params])
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await call(path, try JSONSerialization.data(withJSONObject: body))
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.refused(code: "bad_reply") }
        if let error = reply["error"] as? [String: Any], reply["ok"] as? Bool != true, reply["value"] == nil {
            throw Failure.refused(code: error["code"] as? String ?? "unknown")
        }
        return reply
    }

    /// The id of the open approve item for `request`: for `team` (the
    /// create's own team, never another team the person belongs to), posted
    /// by that team's Cloud owner (`system:cloud:<team>`), for `op`, with the
    /// same digest; nil for any other item.
    static func item(carrying request: String, op: String, digest: String, team: String, in reply: [String: Any]) -> String? {
        let items = (reply["value"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.first { item in
            let action = (item["prompt"] as? [String: Any])?["action"] as? [String: Any]
            let approval = (action?["input"] as? [String: Any])?["approval"] as? [String: Any]
            let poster = item["poster"] as? [String: Any]
            guard approval?["request"] as? String == request, approval?["digest"] as? String == digest,
                  action?["tool"] as? String == op, !team.isEmpty, approval?["team"] as? String == team else { return false }
            return poster?["kind"] as? String == "integration" && poster?["scope"] as? String == "system:cloud:\(team)"
        }?["id"] as? String
    }
}

extension CloudApprovalAnswer.Failure {
    /// The approval item for `request` is no longer open to answer: an attempt already answered it. The
    /// request has ended ("state"), or, after an attempt with this key began answering it
    /// (`answeredEarlier`), it still reads pending (`integration.approval.get` shows a running approved op
    /// as pending) while its feed item is closed.
    public func alreadyAnswered(request: String, answeredEarlier: Bool) -> Bool {
        switch self {
        case .mismatch(let r, let reason) where r == request:
            reason == "state" || (answeredEarlier && reason == CloudApprovalAnswer.closedItem)
        case .answered(let r): answeredEarlier && r == request
        case .notInFeed, .mismatch, .refused: false
        }
    }

    /// The person answered `request` elsewhere (this team's item is closed); not answered here. Another
    /// team's item, or none, is the closed-item mismatch, which fails (cmux#32354).
    public func answeredElsewhere(request: String) -> Bool {
        if case .answered(request) = self { true } else { false }
    }
}

extension CloudApprovalAnswer.Failure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notInFeed, .answered: CloudStrings.createApproveInFeed
        case .mismatch: CloudStrings.createApprovalMismatch
        case .refused(let code): "\(CloudStrings.createApproveInFeed) (\(code))"
        }
    }
}

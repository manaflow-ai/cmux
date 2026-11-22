public import CmuxNextDaemon
import CmuxNextCloud
public import Foundation
import os

/// Answers one G8 approval request (`apr_…`, cx-wb5.65) as the signed-in
/// person's own session, only when it is the create the person confirmed:
///
/// cmux-api's `integration.approval.approve` checks and answers it in one call,
/// carrying the approved run's reply; a backend without it gets the same three
/// checks as calls (Rust decides each, cmux-cloud-start-core `approval_answer`):
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
    /// install token's team, captured when the person confirmed). Returns the
    /// approved run's answer (`{machine, …}`) when the backend carried it in the
    /// same call, so the create needs no same-key retry; nil otherwise.
    @discardableResult
    public func approve(request: String, op: String, params: Data, team: String) async throws -> JSONValue? {
        do {
            return try await checkedApprove(request: request, op: op, params: params, team: team)
        } catch let failure as Failure {
            if case .mismatch(_, let reason) = failure {
                Self.logger.error("approval \(request, privacy: .public) refused: \(reason, privacy: .public) differs")
            }
            throw failure
        }
    }

    /// Rust decides every call and the outcome (cmux-cloud-start-core `approval_answer`, op `cloud_approval_next`): the
    /// one-call `integration.approval.approve`, or the three calls on a backend without it. This only makes the calls.
    private func checkedApprove(request: String, op: String, params: Data, team: String) async throws -> JSONValue? {
        if let answered, await answered(request, team) { throw Failure.answered(request: request) }
        let confirmed = try JSONSerialization.jsonObject(with: params)
        var steps: [Any] = []
        // At most one call per step of the longest path (one call, then approval.get, two feed.list, feed.answer).
        for _ in 0..<8 {
            let ask = try JSONSerialization.data(withJSONObject: ["request": request, "op": op, "params": confirmed, "team": team, "steps": steps])
            guard let data = CloudStartCore().callData("cloud_approval_next", ask, startingCapacity: 16_384),
                  let next = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.refused(code: "core_unavailable") }
            if next["next"] as? String == "call", let path = next["path"] as? String, let body = next["body"] {
                let reply = try await call(path, try JSONSerialization.data(withJSONObject: body))
                steps.append((try? JSONSerialization.jsonObject(with: reply)) ?? [String: Any]())
                continue
            }
            let outcome = next["outcome"] as? [String: Any] ?? [:]
            let reply = (outcome["reply"]).flatMap { $0 is NSNull ? nil : (try? JSONSerialization.data(withJSONObject: $0)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
            switch outcome["kind"] as? String {
            case "approved": return reply
            case "answeredElsewhere": throw Failure.answered(request: request)
            case "mismatch": throw Failure.mismatch(request: request, reason: outcome["reason"] as? String ?? "params")
            default: throw Failure.refused(code: outcome["code"] as? String ?? "unknown")
            }
        }
        throw Failure.refused(code: "too_many_steps")
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

extension CloudApprovalAnswer.Failure: CustomStringConvertible, LocalizedError {
    /// What a person reads for it (`PlainErrorText.personal`), not "Something went wrong".
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .notInFeed, .answered: CloudStrings.createApproveInFeed
        case .mismatch: CloudStrings.createApprovalMismatch
        case .refused(let code): "\(CloudStrings.createApproveInFeed) (\(code))"
        }
    }
}

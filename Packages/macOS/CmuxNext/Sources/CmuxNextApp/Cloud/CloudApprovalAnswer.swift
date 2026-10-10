import Foundation

/// Answers one G8 approval request (`apr_…`, cx-wb5.65) as the signed-in
/// person's own session, only when it is the create the person confirmed:
///
/// 1. `integration.approval.get {request}` (session only) must name `op`,
///    be pending, and carry exactly the confirmed params;
/// 2. the open feed approve item that carries the request must be posted by
///    `system:cloud:<team>` for that op, with the same digest;
/// 3. then `feed.answer {decision: allow, scope: once}`, origin `user`.
///
/// Any mismatch refuses and answers nothing. The backend accepts an
/// integration approval only from a session (domains/feed.ts), so an
/// install, an app or an agent can never answer one. Called only by
/// ``CloudMachineCreateFlow`` after the person's native confirmation.
nonisolated struct CloudApprovalAnswer: Sendable {
    /// One POST of a JSON body to the API Worker as the signed-in person
    /// (`v1/read`, `v1/ops`); returns the reply body.
    typealias Call = @Sendable (_ path: String, _ body: Data) async throws -> Data

    enum Failure: Error, Equatable {
        /// No open approval item in the feed carries the request.
        case notInFeed(request: String)
        /// The request is not the create the person confirmed.
        case mismatch(request: String, reason: String)
        case refused(code: String)
    }

    let call: Call

    /// Approves `request` when it holds `op` with exactly `params` (a JSON object).
    func approve(request: String, op: String, params: Data) async throws {
        let read = try await post("v1/read", ["op": "integration.approval.get", "params": ["request": request]])
        let held = read["value"] as? [String: Any] ?? [:]
        guard held["op"] as? String == op else { throw Failure.mismatch(request: request, reason: "op") }
        guard held["state"] as? String == "pending" else { throw Failure.mismatch(request: request, reason: "state") }
        let confirmed = try JSONSerialization.jsonObject(with: params) as? NSDictionary
        guard let confirmed, let heldParams = held["params"] as? NSDictionary, heldParams.isEqual(confirmed) else {
            throw Failure.mismatch(request: request, reason: "params")
        }
        guard let digest = held["digest"] as? String else { throw Failure.mismatch(request: request, reason: "digest") }
        let list = try await post("v1/read", ["op": "feed.list", "params": [
            "state": "open", "type": "request", "kind": "approve", "poster_kind": "integration", "limit": 100,
        ]])
        guard let item = Self.item(carrying: request, op: op, digest: digest, in: list) else { throw Failure.notInFeed(request: request) }
        let reply = try await post("v1/ops", ["op": "feed.answer", "origin": "user", "idempotency_key": "approve:\(request)",
                                              "params": ["item": item, "answer": ["decision": "allow", "scope": "once"]]])
        if reply["ok"] as? Bool == false {
            throw Failure.refused(code: (reply["error"] as? [String: Any])?["code"] as? String ?? "unknown")
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await call(path, try JSONSerialization.data(withJSONObject: body))
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.refused(code: "bad_reply") }
        if let error = reply["error"] as? [String: Any], reply["ok"] as? Bool != true, reply["value"] == nil {
            throw Failure.refused(code: error["code"] as? String ?? "unknown")
        }
        return reply
    }

    /// The id of the open approve item for `request`: posted by the Cloud
    /// owner of the approval's team (`system:cloud:<team>`), for `op`, with
    /// the same digest; nil for any other item.
    static func item(carrying request: String, op: String, digest: String, in reply: [String: Any]) -> String? {
        let items = (reply["value"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.first { item in
            let action = (item["prompt"] as? [String: Any])?["action"] as? [String: Any]
            let approval = (action?["input"] as? [String: Any])?["approval"] as? [String: Any]
            let poster = item["poster"] as? [String: Any]
            guard approval?["request"] as? String == request, approval?["digest"] as? String == digest,
                  action?["tool"] as? String == op, let team = approval?["team"] as? String, !team.isEmpty else { return false }
            return poster?["kind"] as? String == "integration" && poster?["scope"] as? String == "system:cloud:\(team)"
        }?["id"] as? String
    }
}

extension CloudApprovalAnswer.Failure: CustomStringConvertible {
    var description: String {
        switch self {
        case .notInFeed: CloudStrings.createApproveInFeed
        case .mismatch(_, let reason): "\(CloudStrings.createApprovalMismatch) (\(reason))"
        case .refused(let code): "\(CloudStrings.createApproveInFeed) (\(code))"
        }
    }
}

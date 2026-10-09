import Foundation

/// Answers one G8 approval request (`apr_…`, cx-wb5.65) as the signed-in
/// person's own session: finds the open feed approve item that carries the
/// request (`prompt.action.input.approval.request`) and sends `feed.answer
/// {decision: allow, scope: once}` with origin `user`. The backend accepts
/// an integration approval only from a session (domains/feed.ts), so an
/// install, an app or an agent can never answer one. Called only by
/// ``CloudMachineCreateFlow`` after the person's native confirmation.
nonisolated struct CloudApprovalAnswer: Sendable {
    /// One POST of a JSON body to the API Worker as the signed-in person
    /// (`v1/read`, `v1/ops`); returns the reply body.
    typealias Call = @Sendable (_ path: String, _ body: Data) async throws -> Data

    enum Failure: Error, Equatable {
        /// No open approval item in the feed carries the request.
        case notInFeed(request: String)
        case refused(code: String)
    }

    let call: Call

    func approve(request: String) async throws {
        let list = try await post("v1/read", ["op": "feed.list", "params": [
            "state": "open", "type": "request", "kind": "approve", "poster_kind": "integration", "limit": 100,
        ]])
        guard let item = Self.item(carrying: request, in: list) else { throw Failure.notInFeed(request: request) }
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

    /// The id of the open approve item whose approval is `request`.
    static func item(carrying request: String, in reply: [String: Any]) -> String? {
        nil // red
    }
}

extension CloudApprovalAnswer.Failure: CustomStringConvertible {
    var description: String {
        switch self {
        case .notInFeed: CloudStrings.createApproveInFeed
        case .refused(let code): "\(CloudStrings.createApproveInFeed) (\(code))"
        }
    }
}

import CmuxNextCloud
public import Foundation

/// Settings → Cloud → Spending's overage save (RFD 0080 "Spend controls"): cmux-api `usage.cap.set {overage_usd}` as
/// the signed-in person's own session (the op takes only a session: an install, an app or an agent can never set it).
///
/// Rust decides the call and words the outcome (cmux-cloud-start-core `spending_write`, op `cloud_spending_set_next`);
/// this only makes the call and hands the outcome on, as JSON: `{kind: saved, overageUsd, teamCapUsd}`,
/// `{kind: invalid, message}` or `{kind: refused, code, message, retry}`.
public nonisolated struct CloudSpendingWrite: Sendable {
    let call: CloudApprovalAnswer.Call

    public init(call: @escaping CloudApprovalAnswer.Call) {
        self.call = call
    }

    /// Saves `overageUsd` (nil: overage off) under `key`, one key per save (a retry of the same save reuses it).
    /// Returns the outcome's JSON; a failed call is Rust's `refused` for that reply.
    public func save(overageUsd: Double?, key: String) async -> Data {
        var steps: [Any] = []
        // One call, then the outcome; the bound only keeps a wrong answer from looping.
        for _ in 0..<3 {
            let ask: [String: Any] = ["overageUsd": overageUsd.map { $0 as Any } ?? NSNull(), "key": key, "steps": steps]
            guard let request = try? JSONSerialization.data(withJSONObject: ask),
                  let data = CloudStartCore().callData("cloud_spending_set_next", request, startingCapacity: 4_096),
                  let next = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self.refused("core_unavailable") }
            guard next["next"] as? String == "call", let path = next["path"] as? String, let body = next["body"] else {
                return (next["outcome"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Self.refused("unknown")
            }
            do {
                let reply = try await call(path, try JSONSerialization.data(withJSONObject: body))
                steps.append((try? JSONSerialization.jsonObject(with: reply)) ?? [String: Any]())
            } catch {
                // No answer: Rust words it like the backend's own unreachable owner, a retry with the same key.
                steps.append(["ok": false, "error": ["code": "network"]])
            }
        }
        return Self.refused("too_many_steps")
    }

    private static func refused(_ code: String) -> Data {
        let outcome: [String: Any] = ["kind": "refused", "code": code, "message": "Couldn't save the overage limit. Try again.", "retry": false]
        return (try? JSONSerialization.data(withJSONObject: outcome)) ?? Data()
    }
}

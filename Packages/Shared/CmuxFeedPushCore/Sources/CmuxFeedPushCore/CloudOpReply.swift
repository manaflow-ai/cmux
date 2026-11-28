import Foundation

/// The API Worker's answer to `POST /v1/ops`. A domain refusal is HTTP 200
/// with `ok: false`, so the status code alone never means success.
public enum CloudOpReply: Hashable, Sendable {
    case committed(replayed: Bool)
    case rejected(code: String, retryable: Bool)

    /// Decodes the body; an unreadable body is a refusal (fail closed).
    public init(body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            self = .rejected(code: "invalid_reply", retryable: true)
            return
        }
        if ok {
            self = .committed(replayed: object["replayed"] as? Bool ?? false)
        } else {
            let error = object["error"] as? [String: Any]
            self = .rejected(code: error?["code"] as? String ?? "unknown",
                             retryable: error?["retryable"] as? Bool ?? false)
        }
    }
}

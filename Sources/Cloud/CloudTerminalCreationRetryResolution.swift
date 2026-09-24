import CmuxSurfaceCatalogModel
import Foundation

/// The daemon's authoritative permission for one explicit terminal-creation retry.
enum CloudTerminalCreationRetryResolution: Equatable, Sendable {
    case created(CmuxTuiSnapshotParser.CreatedTerminalPath)
    case sameAttempt
    case newAttempt
    case pending
    case indeterminate

    init?(data: Data, correlationKey: String, attemptKey: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let envelope = (object["result"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? object
        let value = (envelope["value"] as? [String: Any]) ?? envelope
        guard value["correlation_key"] as? String == correlationKey,
              let state = value["state"] as? String,
              let recovery = value["recovery"] as? String else { return nil }
        let returnedKey = value["idempotency_key"] as? String
        // An absent record can authorize a new attempt without an old key.
        // Every existing receipt must name this request's current attempt.
        guard returnedKey == attemptKey ||
            (returnedKey == nil && state == "not_applied" && recovery == "retry_new_idempotency_key") else { return nil }
        switch (state, recovery) {
        case ("created", "none"):
            guard let path = value["created_path"] as? [String: Any],
                  path["kind"] as? String == "terminal",
                  let generation = value["generation"] as? String, !generation.isEmpty,
                  let revision = CloudWireNumber.unsigned(value["revision"]),
                  let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: [
                    "value": path, "generation": generation, "revision": String(revision)
                  ]),
                  created.workspaceID != nil, created.screenID != nil,
                  created.paneID != nil, created.tabID != nil else { return nil }
            self = .created(created)
        case ("not_applied", "retry_same_idempotency_key"):
            self = .sameAttempt
        case ("not_applied", "retry_new_idempotency_key"):
            self = .newAttempt
        case ("pending", "wait"):
            self = .pending
        case ("indeterminate", "do_not_retry"):
            self = .indeterminate
        default:
            return nil
        }
    }
}

import Foundation

/// The durable answer for one correlated resource creation intent.
///
/// A `workspace run` response can be lost after the daemon commits. The
/// `session.creation.resolve` command returns this same state machine so the
/// client can retry only when the daemon explicitly says that doing so is safe.
struct CloudTuiCreationResolution: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case pending
        case created
        case notApplied = "not_applied"
        case indeterminate
    }

    enum Recovery: String, Equatable, Sendable {
        case retrySameIdempotencyKey = "retry_same_idempotency_key"
        case retryNewIdempotencyKey = "retry_new_idempotency_key"
        case wait
        case none
        case doNotRetry = "do_not_retry"
    }

    let correlationKey: String
    let state: State
    let recovery: Recovery
    let idempotencyKey: String?
    let createdTerminal: CmuxTuiSnapshotParser.CreatedTerminalPath?

    /// Decodes either the direct `session.creation.resolve` object or the
    /// `MutationResult` wrapper emitted by a compatible client bridge.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        self.init(object: object)
    }

    /// Decodes one JSON object while enforcing the state/recovery contract.
    init?(object: [String: Any]) {
        let payload = (object["result"] as? [String: Any])
            ?? (object["data"] as? [String: Any])
            ?? object
        let value = (payload["value"] as? [String: Any]) ?? payload
        guard let correlationKey = Self.nonEmptyString(value["correlation_key"]),
              let stateRaw = Self.nonEmptyString(value["state"]),
              let state = State(rawValue: stateRaw),
              let recoveryRaw = Self.nonEmptyString(value["recovery"]),
              let recovery = Recovery(rawValue: recoveryRaw) else {
            return nil
        }

        let idempotencyKey = Self.nonEmptyString(value["idempotency_key"])
        var createdTerminal: CmuxTuiSnapshotParser.CreatedTerminalPath?
        if state == .created {
            guard recovery == .none,
                  let path = value["created_path"] as? [String: Any],
                  let generation = Self.nonEmptyString(value["generation"])
                    ?? Self.nonEmptyString(payload["generation"])
                    ?? Self.nonEmptyString(object["generation"]),
                  let revision = CloudWireNumber.unsigned(value["revision"])
                    ?? CloudWireNumber.unsigned(payload["revision"])
                    ?? CloudWireNumber.unsigned(object["revision"]) else {
                return nil
            }
            let result: [String: Any] = [
                "value": path,
                "generation": generation,
                "revision": String(revision),
            ]
            guard let parsed = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: result) else {
                return nil
            }
            createdTerminal = parsed
        }

        switch (state, recovery) {
        case (.pending, .wait),
             (.notApplied, .retrySameIdempotencyKey),
             (.notApplied, .retryNewIdempotencyKey),
             (.indeterminate, .doNotRetry),
             (.created, .none):
            break
        default:
            return nil
        }

        self.correlationKey = correlationKey
        self.state = state
        self.recovery = recovery
        self.idempotencyKey = idempotencyKey
        self.createdTerminal = createdTerminal
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Backoff used while a daemon is still executing a correlated creation.
///
/// This is an explicit progress wait, rather than a settling delay: the loop
/// ends only at a durable creation state or caller cancellation.
struct CloudTuiCreationRecoveryPolicy: Equatable, Sendable {
    let delays: [Duration]

    init(delays: [Duration]) {
        precondition(!delays.isEmpty)
        precondition(delays.allSatisfy { $0 > .zero })
        self.delays = delays
    }

    static let standard = Self(delays: [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ])

    func delay(afterAttempts attempts: Int) -> Duration {
        delays[min(max(attempts, 1), delays.count) - 1]
    }
}

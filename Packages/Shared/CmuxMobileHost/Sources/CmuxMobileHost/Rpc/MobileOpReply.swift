import CmuxMobileWire

/// The frames that answer one op: `result` or `reject`, then `request-settled`.
public struct MobileOpReply: Hashable, Sendable {
    public var idempotencyKey: String
    public var stream: String
    public var outcome: MobileOpOutcome
    public var replayed: Bool

    public init(idempotencyKey: String, stream: String, outcome: MobileOpOutcome, replayed: Bool) {
        self.idempotencyKey = idempotencyKey
        self.stream = stream
        self.outcome = outcome
        self.replayed = replayed
    }

    public var frames: [MobileFrame] {
        switch outcome {
        case .result(let tx, let value, let sequence):
            return [
                .result(ResultFrame(tx: tx, idempotencyKey: idempotencyKey, value: value, revision: String(sequence),
                                    replayed: replayed)),
                .settled(SettledFrame(tx: tx, idempotencyKey: idempotencyKey, stream: stream, sequence: sequence, ok: true)),
            ]
        case .reject(let tx, let rejection):
            return [
                .reject(RejectFrame(tx: tx, idempotencyKey: idempotencyKey, code: rejection.code, message: rejection.message,
                                    details: rejection.details, retryable: rejection.retryable, replayed: replayed)),
                .settled(SettledFrame(tx: tx, idempotencyKey: idempotencyKey, stream: stream, sequence: 0, ok: false)),
            ]
        }
    }
}

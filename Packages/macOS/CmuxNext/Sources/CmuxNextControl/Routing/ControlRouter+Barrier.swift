public import CmuxNextSettings

/// The read barrier every method accepts (plans/cmux-next/state-ownership.md 4.3).
///
/// `after` is either a number, the `sequence` an earlier app reply printed
/// (`action.run`, `snapshot.get`), or `"sync"`, which first asks the local
/// daemon for the event sequence that covers every write it committed so
/// far (writes the CLI sent to the daemon directly). The request then
/// answers from the first published snapshot that reflects that sequence,
/// within its deadline, so targets resolve against state that includes
/// the caller's writes.
extension ControlRouter {
    func readBarrier(_ after: JSONValue, method: String, deadline: ContinuousClock.Instant) async throws -> ControlSnapshot {
        let sequence: UInt64
        switch after {
        // `Double(UInt64.max)` rounds up to 2^64, which `UInt64` cannot hold;
        // a full-width sequence goes as a string.
        case .number(let value) where value.isFinite && value >= 0 && value < Double(UInt64.max) && value == value.rounded():
            sequence = UInt64(value)
        case .string(let text) where UInt64(text) != nil:
            sequence = UInt64(text) ?? 0
        case .string("sync"):
            // Not registered yet (the socket serves before the App wires the
            // daemon): answering from the current snapshot would skip the sync.
            guard let barrier = syncBarrier else {
                throw ControlError(code: "unavailable", message: ControlStrings.text("control.error.syncBarrierUnavailable",
                                                                                     "after: \"sync\" is not available yet; retry"))
            }
            sequence = try await ControlDeadline.shared.run(method: method, deadline: deadline) { try await barrier() }
        default:
            throw ControlError.invalidParams(ControlStrings.text("control.error.afterShape",
                                                                 "after must be a sequence number from an earlier reply or \"sync\""))
        }
        guard let snapshot = await snapshots.snapshot(reflecting: sequence, deadline: deadline) else {
            var error = ControlError.timeout(method, after: .zero)
            error.data = ["method": .string(method), "after": JSONValue.number(Double(sequence)),
                          "sequence": JSONValue.number(Double(snapshots.current.topology.daemonSequence))]
            throw error
        }
        return snapshot
    }
}

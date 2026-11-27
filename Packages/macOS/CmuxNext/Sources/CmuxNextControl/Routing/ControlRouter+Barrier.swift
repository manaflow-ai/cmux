public import CmuxNextSettings

/// The read barrier every method accepts (plans/cmux-next/state-ownership.md 4.3).
///
/// `after` is either a number, the `sequence` an earlier app reply printed
/// (`action.run`, `snapshot.get`), or `"sync"`, which first asks the local
/// daemon for the event sequence that covers every write it committed so
/// far (writes the CLI sent to the daemon directly). The request then
/// answers from the first published snapshot that reflects that sequence,
/// within `limit`, so targets resolve against state that includes the
/// caller's writes.
///
/// The daemon round trip has no wall clock (#32724): on a loaded Mac it
/// answers late, and a deadline there failed requests on a healthy app and
/// daemon. It waits while the daemon connection lives (the App's barrier asks
/// with no deadline; the connection ends only when the daemon process is
/// gone). `limit` counts from its answer. A barrier that fails says the app did not get to
/// the request (`unavailable`, `state: "not_run"`), which the CLI asks again for.
extension ControlRouter {
    func readBarrier(_ after: JSONValue, method: String, limit: Duration) async throws -> ControlSnapshot {
        let sequence: UInt64
        switch after {
        // `Double(UInt64.max)` rounds up to 2^64, which `UInt64` cannot hold;
        // a full-width sequence goes as a string.
        // UInt64(exactly:) is nil for fractions, negatives, NaN, infinity and 2^64.
        case .number(let value) where UInt64(exactly: value) != nil:
            sequence = UInt64(exactly: value) ?? 0
        case .string(let text) where UInt64(text, radix: 10) != nil:
            sequence = UInt64(text, radix: 10) ?? 0
        case .string("sync"):
            // Not registered yet (the socket serves before the App wires the
            // daemon): answering from the current snapshot would skip the sync.
            guard let barrier = syncBarrier else { throw Self.syncBarrierNotRun() }
            do {
                sequence = try await barrier()
            } catch {
                throw Self.syncBarrierNotRun(cause: error)
            }
        default:
            throw ControlError.invalidParams(ControlStrings.text("control.error.afterShape",
                                                                 "after must be a sequence number from an earlier reply or \"sync\""))
        }
        guard let snapshot = await snapshots.snapshot(reflecting: sequence, deadline: .now + limit) else {
            var error = ControlError.timeout(method, after: .zero)
            error.data = ["method": .string(method), "after": JSONValue.number(Double(sequence)),
                          "sequence": JSONValue.number(Double(snapshots.current.topology.daemonSequence))]
            throw error
        }
        return snapshot
    }

    /// The barrier did not run (not registered yet, or the daemon connection ended before it
    /// answered): nothing ran, so the caller may send the request again.
    static func syncBarrierNotRun(cause: (any Error)? = nil) -> ControlError {
        var data: [String: JSONValue] = ["not_run": true, "state": "not_run", "retry_after_ms": 200]
        if let cause { data["cause"] = .string(String(describing: cause)) }
        return ControlError(code: "unavailable",
                            // retry-prompt-ok: a socket API reply to a script, which owns its own retry
                            message: ControlStrings.text("control.error.syncBarrierUnavailable", "after: \"sync\" is not available yet; retry"),
                            data: .object(data))
    }

    /// The methods that act on a pane, named or the focused one: each waits out the launch layout (``settledLayout(method:)``).
    static let layoutDependentMethods: Set<String> = ["action.run", "action.batch", "browser.open_split", "file.open", "palette.run"]

    /// Default ``Configuration/layoutSettleDeadline``: Home's first dock move is a few daemon replies, about a second
    /// after the live tree on a fresh launch (vw4a-div-2-r2: 1.3 s).
    public static let layoutSettleLimit: Duration = .seconds(10)

    /// The launch barrier: the first published snapshot in which no launch step can still retire a pane it lists
    /// (`ControlTopology.isSettling`: Home's first dock move closes the pane Home's page opened in). A method that
    /// acted on the earlier snapshot could aim at that pane and reach the daemon after the move ("unknown pane").
    /// Past ``Configuration/layoutSettleDeadline`` nothing ran, and the caller may ask again.
    func settledLayout(method: String) async throws -> ControlSnapshot {
        if let snapshot = await snapshots.snapshot(where: { !$0.topology.isSettling }, deadline: .now + configuration.layoutSettleDeadline) {
            return snapshot
        }
        throw Self.layoutSettlingNotRun(method)
    }

    /// The launch layout did not settle in time: nothing ran, so the caller may send the request again.
    static func layoutSettlingNotRun(_ method: String) -> ControlError {
        ControlError(code: "unavailable",
                     // retry-prompt-ok: a socket API reply to a script, which owns its own retry
                     message: ControlStrings.text("control.error.layoutSettling", "cmux is still placing its windows; retry"),
                     data: ["method": .string(method), "not_run": true, "state": "not_run", "retry_after_ms": 200])
    }
}

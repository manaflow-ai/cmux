#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextWakeups
internal import CmuxNextSettings

/// `debug.observations`: per observer owner, the observations armed now, their arms, evaluations
/// and applies, the show re-reads with their time, and the SwiftUI hosting body evaluations (all
/// and hidden), since launch or the last reset (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Observers per event"). `{"owner": "<prefix>"}` keeps only owners whose name starts with it;
/// `{"reset": true}` zeroes the reported owners' counts as it reads them (one atomic exchange per
/// count, so no event is lost) and leaves the other owners' counts alone. The report reads atomics
/// only, so it runs off the main thread and answers while the main thread is busy.
public struct ObservationsControl: Sendable {
    private let ledger: ObservationLedger

    /// Makes the method over the composition root's ledger.
    public init(ledger: ObservationLedger) {
        self.ledger = ledger
    }

    /// The `debug.observations` control method.
    public var method: ControlMethod {
        .snapshot("debug.observations") { [ledger] call in Self.report(call.params, ledger: ledger) }
    }

    static func report(_ params: [String: JSONValue], ledger: ObservationLedger) -> JSONValue {
        let entries = ledger.snapshot(matching: params["owner"]?.stringValue ?? "",
                                      resetting: params["reset"]?.boolValue == true)
        return .object([
            "totals": .object([
                "armed": JSONValue(entries.reduce(0) { $0 + $1.armed }),
                "evaluations": count(entries.reduce(0) { $0 &+ $1.evaluations }),
                "applies": count(entries.reduce(0) { $0 &+ $1.applies }),
                "body_evaluations": count(entries.reduce(0) { $0 &+ $1.bodyEvaluations }),
                "hidden_body_evaluations": count(entries.reduce(0) { $0 &+ $1.hiddenBodyEvaluations }),
            ]),
            "owners": .array(entries.map { entry in
                .object([
                    "owner": .string(entry.owner),
                    "armed": JSONValue(entry.armed),
                    "arms": count(entry.arms),
                    "evaluations": count(entry.evaluations),
                    "applies": count(entry.applies),
                    "show_rereads": count(entry.showRereads),
                    "show_reread_ms": milliseconds(entry.showRereadNanos),
                    "show_reread_max_ms": milliseconds(entry.showRereadMaxNanos),
                    "body_evaluations": count(entry.bodyEvaluations),
                    "hidden_body_evaluations": count(entry.hiddenBodyEvaluations),
                ])
            }),
        ])
    }

    private static func count(_ value: UInt64) -> JSONValue {
        .number(Double(value))
    }

    private static func milliseconds(_ nanos: UInt64) -> JSONValue {
        .number(Double(nanos) / 1e6)
    }
}
#endif

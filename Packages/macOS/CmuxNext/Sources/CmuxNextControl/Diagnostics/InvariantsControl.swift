#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInvariants
public import CmuxNextSettings
import Foundation
#else
internal import CmuxNextSettings
#endif

/// `debug.invariants` (plans/cmux-next/invariants-DESIGN.md section 5.1): the invariant ledger, which journeys, the
/// focus fuzz and the R4 differential read after every step and fail on. Params (all optional): `since` (only the
/// violations after this sequence number), `check` (run every turn rule now, on every subject), `ipc` (also run the
/// harness rules; their reads may await another process), `ids` (limit `check` to these rules), `rules` (the rule
/// table with counts and run times), `state` (each parity rule's read state), `clear` (forget which signatures were
/// reported; the sequence numbers go on).
///
/// ```json
/// {"armed": true, "mode": "on", "seq": 42, "oldest_seq": 1, "dropped": false, "turns_checked": 18234,
///  "violations": [{"seq": 41, "id": "W10", "host": "app", "subject": {"window": "w2"}, "detail": "...",
///                  "trigger": {"kind": "action", "actions": [{"id": "pane.split", "origin": "user", "index": 77}],
///                              "turn": 9921, "frame_seq": null}, "state": {}, "report": "..."}]}
/// ```
///
/// Before the registry starts (the `InputVerification.start` launch post) it answers `{"armed": false, "mode":
/// "starting"}`. A Release build answers `{"armed": false, "mode": "release"}`: it has no checker. A harness reads
/// `armed: false` as "not run", never as a clean ledger.
public struct InvariantsControl: Sendable {
    #if DEBUG || CMUX_BENCH_HOOKS
    private let registry: @MainActor @Sendable () -> InvariantRegistry?

    /// The method over the app's registry, read at each request (nil until it starts).
    public init(registry: @escaping @MainActor @Sendable () -> InvariantRegistry?) {
        self.registry = registry
    }

    /// The `debug.invariants` control method.
    public var method: ControlMethod {
        .mainActor("debug.invariants") { [registry] call in
            guard let registry = registry() else { return .value(.object(["armed": .bool(false), "mode": .string("starting")])) }
            return Self.answer(call.params, registry: registry)
        }
    }

    @MainActor
    static func answer(_ params: [String: JSONValue], registry: InvariantRegistry) -> ControlReply {
        if params["clear"]?.boolValue == true { registry.clearReported() }
        let ids = params["ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue).map(InvariantID.init(rawValue:))) }
        let current = params["check"]?.boolValue == true ? registry.checkNow(ids: ids) : nil
        guard params["check"]?.boolValue == true, params["ipc"]?.boolValue == true else {
            return .value(reply(params, registry: registry, current: current))
        }
        // The harness rules await their peers: the main thread is not held meanwhile, and the reply is built on
        // the main actor once they are in.
        return .followUp {
            let harness = await registry.checkHarness(ids: ids)
            return await reply(params, registry: registry, current: (current ?? []) + harness)
        }
    }

    @MainActor
    static func reply(_ params: [String: JSONValue], registry: InvariantRegistry,
                      current: [(id: InvariantID, finding: InvariantFinding)]?) -> JSONValue {
        let since = params["since"]?.intValue.map { UInt64(clamping: $0) } ?? 0
        let read = registry.ledger.since(since)
        var fields: [String: JSONValue] = [
            "armed": .bool(registry.isArmed),
            "mode": .string(registry.mode.rawValue),
            "seq": .number(Double(registry.ledger.lastSeq)),
            "oldest_seq": .number(Double(registry.ledger.oldestSeq)),
            "dropped": .bool(read.dropped),
            "turns_checked": .number(Double(registry.turnsChecked)),
            "violations": .array(read.violations.map(json)),
        ]
        if let current {
            fields["current"] = .array(current.map { found in
                .object(["id": .string(found.id.rawValue), "subject": encode(found.finding.subject),
                         "detail": .string(found.finding.detail)])
            })
        }
        if params["rules"]?.boolValue == true {
            fields["rules"] = .array(registry.rules.map { rule in ruleJSON(rule, stats: registry.stats(of: rule.id)) })
            fields["pass_us"] = micros(registry.passStats)
        }
        if params["state"]?.boolValue == true {
            fields["state"] = .object(registry.paritySnapshot().reduce(into: [:]) { object, entry in
                object[entry.key.rawValue] = (try? JSONValue.parse(entry.value)) ?? .null
            })
        }
        return .object(fields)
    }

    /// One violation as `debug.invariants` and the report file give it.
    public nonisolated static func json(_ violation: InvariantViolation) -> JSONValue {
        let trigger = violation.trigger
        var triggerFields: [String: JSONValue] = [
            "kind": .string(trigger.kind.rawValue),
            "actions": .array(trigger.actions.map { cause in
                .object(["id": .string(cause.id), "origin": .string(cause.origin), "index": .number(Double(cause.index))])
            }),
            "turn": .number(Double(trigger.turn)),
            "frame_seq": trigger.frameSeq.map { .number(Double($0)) } ?? .null,
        ]
        if let fileID = trigger.fileID { triggerFields["file"] = .string(fileID) }
        if let line = trigger.line { triggerFields["line"] = .number(Double(line)) }
        return .object([
            "seq": .number(Double(violation.seq)),
            "id": .string(violation.id.rawValue),
            "host": .string(violation.host),
            "subject": encode(violation.subject),
            "detail": .string(violation.detail),
            "trigger": .object(triggerFields),
            "state": violation.state.flatMap { try? JSONValue.parse($0) } ?? .null,
            "journal_tail": violation.journalTail.map { .number(Double($0)) } ?? .null,
            "report": violation.report.map(JSONValue.string) ?? .null,
        ])
    }

    @MainActor
    private static func ruleJSON(_ rule: InvariantRule, stats: InvariantRuleStats?) -> JSONValue {
        .object([
            "id": .string(rule.id.rawValue),
            "statement": .string(rule.statement),
            "owner": .string(rule.owner),
            "points": .array(rule.points.names.map(JSONValue.string)),
            "reads": .array(rule.reads.map(\.rawValue).sorted().map(JSONValue.string)),
            "cost": .string(rule.cost.rawValue),
            "liveness": .bool(rule.isLiveness),
            "checks": .number(Double(stats?.checks ?? 0)),
            "violations": .number(Double(stats?.violations ?? 0)),
            "us": stats.map(micros) ?? .null,
            "interim": rule.interim.map(JSONValue.string) ?? .null,
        ])
    }

    private nonisolated static func micros(_ stats: InvariantRuleStats) -> JSONValue {
        .object(["p50": .number(stats.p50), "p95": .number(stats.p95), "p99": .number(stats.p99),
                 "max": .number(stats.max), "runs": .number(Double(stats.checks))])
    }

    private nonisolated static func encode(_ subject: InvariantSubject) -> JSONValue {
        guard let data = try? JSONEncoder().encode(subject) else { return .null }
        return (try? JSONValue.parse(data)) ?? .null
    }
    #else
    public init() {}

    /// The `debug.invariants` control method; Release serves it with no state in the reply: it has no checker.
    public var method: ControlMethod {
        .snapshot("debug.invariants") { _ in .object(["armed": .bool(false), "mode": .string("release")]) }.servingRelease()
    }
    #endif
}

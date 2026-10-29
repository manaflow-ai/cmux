import CmuxNextCompat
import CmuxNextControl
import CmuxNextInputModel
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInvariants
#endif
import CmuxNextSettings
import Foundation

// Input verification over the control socket (plans/cmux-next/input-spec.md):
// `debug.invariants` (the invariant ledger, plans/cmux-next/invariants-DESIGN.md) and its one-train alias
// `debug.desync`, `debug.journal` (the ring), `debug.replay` (journal against the pure reducers), and in
// DEBUG builds `debug.mouse` (synthesized mouse input).
extension AppControl {
    func registerInputMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("debug.journal") { call in .value(Self.journal(call.params)) },
            .mainActor("debug.replay") { [weak services] call in
                let source = call.params["source"]?.stringValue ?? "journal"
                let entries: [InputJournalEntry]
                if source == "report" {
                    guard let journal = services?.input.lastReportJournal else { return .value(["error": "no invariant report"]) }
                    entries = journal
                } else {
                    entries = InputJournal.shared.entries()
                }
                return .value(Self.encode(InputInvariants.replay(entries).run()))
            },
        ])
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            // The registry starts with the `InputVerification.start` post, which may come after this registration.
            InvariantsControl { [weak services] in services?.input.invariants }.method,
            .mainActor("debug.desync") { [weak services] call in
                guard let registry = services?.input.invariants else { return .value(.null) }
                return .value(Self.desync(call.params, registry: registry))
            },
            // This app's own light/dark override (never the system's).
            .mainActor("debug.appearance") { call in .value(DebugAppearance.handle(call.params)) },
            .mainActor("debug.mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugMouse.send(call.params, services: services))
            },
            // The Home data path (homeRouter) from the socket (DebugHomeAPI).
            .async("debug.home.api") { [weak services] call in
                guard let services else { return .null }
                return await DebugHomeAPI.handle(call.params, services: services)
            }.withDeadline(.fixed(.seconds(30))),
            .mainActor("debug.home.sidebar_fixture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeSidebarFixture.handle(call.params, services: services))
            },
            .mainActor("debug.tab_drag") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugTabDrag.report(services: services))
            },
        ])
        // `debug.oracle.snapshot` over the app's one facet list (AppServices+OracleHost): the overlays facet.
        service?.router.register(services.oracleControlMethods())
        #else
        service?.router.register([InvariantsControl().method])
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.desync`, the alias of `debug.invariants` for one train (invariants-DESIGN.md section 5.1): `check`
    /// (every turn rule now; `check.violations` lists the current findings as the old monitor did), `clear`, `count`
    /// (violations reported) and `reports` (the ledger's last 16, with their report files).
    private static func desync(_ params: [String: JSONValue], registry: InvariantRegistry) -> JSONValue {
        if params["clear"]?.boolValue == true { registry.clearReported() }
        var fields: [String: JSONValue] = [:]
        if params["check"]?.boolValue == true || params["report"]?.boolValue == true {
            fields["check"] = .object([
                "violations": .array(registry.checkNow().map { found in
                    .object(["invariant": .string(found.id.rawValue), "window": found.finding.subject.windowID.map(JSONValue.string) ?? .null,
                             "detail": .string(found.finding.detail)])
                }),
                "unsettled": .array([]),
            ])
        }
        fields["checks"] = .number(Double(registry.turnsChecked))
        fields["count"] = .number(Double(registry.ledger.lastSeq))
        fields["reports"] = .array(registry.ledger.all.suffix(16).map { violation in
            .object([
                "id": .string("\(violation.seq)-\(violation.id.rawValue)"),
                "path": violation.report.map(JSONValue.string) ?? .null,
                "violations": .array([.string("\(violation.id.rawValue) \(violation.subject): \(violation.detail)")]),
            ])
        })
        return .object(fields)
    }
    #endif

    /// Params: `last` (entries, default 200), `clear`, `marker` (appends a
    /// marker entry first).
    private static func journal(_ params: [String: JSONValue]) -> JSONValue {
        let journal = InputJournal.shared
        if let marker = params["marker"]?.stringValue { journal.append(window: nil, .marker(marker)) }
        if params["clear"]?.boolValue == true { journal.clear() }
        let last = params["last"]?.intValue ?? 200
        return .object([
            "stats": encode(journal.stats),
            "entries": encode(journal.entries(last: last)),
        ])
    }

    static func encode(_ value: some Encodable) -> JSONValue {
        InvariantReportStore.json(value)
    }
}

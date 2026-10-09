import CmuxNextControl
import CmuxNextSettings
import Foundation

// Input verification over the control socket (plans/cmux-next/input-spec.md):
// `debug.desync` (invariant check and captured reports), `debug.journal`
// (the ring), `debug.replay` (journal against the pure reducers), and in
// DEBUG builds `debug.mouse` (synthesized mouse input).
extension AppControl {
    func registerInputMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("debug.desync") { [weak services] call in
                guard let monitor = services?.input.monitor else { return .value(.null) }
                return .value(Self.desync(call.params, monitor: monitor))
            },
            .mainActor("debug.journal") { call in .value(Self.journal(call.params)) },
            .mainActor("debug.replay") { [weak services] call in
                let source = call.params["source"]?.stringValue ?? "journal"
                let entries: [InputJournalEntry]
                if source == "report" {
                    guard let report = services?.input.monitor?.reports.last else { return .value(["error": "no desync report"]) }
                    entries = report.journal
                } else {
                    entries = InputJournal.shared.entries()
                }
                return .value(Self.encode(InputReplay.replay(entries)))
            },
        ])
        #if DEBUG
        service?.router.register([
            // This app's own light/dark override (never the system's).
            .mainActor("debug.appearance") { call in .value(DebugAppearance.handle(call.params)) },
            .mainActor("debug.mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugMouse.send(call.params, services: services))
            },
            .mainActor("debug.tab_drag") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugTabDrag.report(services: services))
            },
        ])
        #endif
    }

    /// Params: `check` (run the world invariants now), `report` (capture a
    /// report now when something is broken; `force` even when nothing is),
    /// `clear`, `full` (the latest report in full).
    private static func desync(_ params: [String: JSONValue], monitor: InputInvariantMonitor) -> JSONValue {
        if params["clear"]?.boolValue == true { monitor.clear() }
        var fields: [String: JSONValue] = [:]
        if params["check"]?.boolValue == true || params["report"]?.boolValue == true, let result = monitor.check() {
            fields["check"] = encode(result)
            if params["report"]?.boolValue == true, !result.violations.isEmpty || params["force"]?.boolValue == true {
                monitor.record(result.violations)
            }
        }
        fields["checks"] = .number(Double(monitor.checks))
        fields["count"] = .number(Double(monitor.reportCount))
        fields["directory"] = monitor.directory.map(JSONValue.string) ?? .null
        fields["reports"] = .array(monitor.reports.map { report in
            .object([
                "id": .string(report.id),
                "path": monitor.url(of: report).map(JSONValue.string) ?? .null,
                "violations": .array(report.summary.map(JSONValue.string)),
            ])
        })
        if params["full"]?.boolValue == true, let latest = monitor.reports.last { fields["latest"] = encode(latest) }
        return .object(fields)
    }

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
        guard let data = try? DesyncReport.encoder.encode(value) else { return .null }
        return (try? JSONValue.parse(data)) ?? .null
    }
}

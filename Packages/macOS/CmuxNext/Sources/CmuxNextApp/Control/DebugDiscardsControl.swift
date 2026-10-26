import CmuxNextControl
import CmuxNextHibernation
import CmuxNextSettings

/// `debug.discards`: cmux's chrome://discards (chrome/browser/ui/webui/discards/discards_ui.cc).
/// One row per content the discard planner's owners report, for every ``ContentKind``: its kind,
/// whether it shows, how long it has been hidden, its lifecycle state, whether it can be discarded
/// and why not, its last discard's reason and how often it woke. It reads the planner's last
/// inputs (`BrowserHibernation.discards`), O(contents tracked); it never walks the session. A kind
/// no owner reports yet is listed with the reason `no_policy`.
///
/// `{"kind": "<kind>"}` keeps one kind's rows. Rows carry tab keys only: no URL, title or path.
@MainActor
enum DebugDiscardsControl {
    static func method(_ services: AppServices) -> ControlMethod {
        .mainActor("debug.discards") { [weak services] call in
            let planner = services?.cache.hibernation?.discards ?? ContentDiscardPlanner()
            return .value(Self.report(planner, params: call.params, now: .now))
        }
    }

    /// The method's answer for `planner` at `now`.
    static func report(_ planner: ContentDiscardPlanner, params: [String: JSONValue] = [:], now: ContinuousClock.Instant) -> JSONValue {
        var only: ContentKind?
        if let raw = params["kind"]?.stringValue {
            guard let kind = ContentKind(rawValue: raw) else {
                return ["error": .string("kind must be one of \(ContentKind.allCases.map(\.rawValue).joined(separator: ", "))")]
            }
            only = kind
        }
        let kinds = planner.kinds.filter { only == nil || $0.kind == only }
        let rows = planner.rows(now: now).filter { only == nil || $0.kind == only }
        return ["kinds": .array(kinds.map(kindJSON)), "contents": .array(rows.map(rowJSON))]
    }

    static func kindJSON(_ summary: ContentDiscardPlanner.KindSummary) -> JSONValue {
        [
            "kind": .string(summary.kind.rawValue), "tracked": .bool(summary.tracked),
            "contents": JSONValue(summary.contents), "discarded": JSONValue(summary.discarded),
            "reason": summary.reason.map { JSONValue.string($0.rawValue) } ?? .null,
        ]
    }

    static func rowJSON(_ row: ContentDiscardPlanner.Row) -> JSONValue {
        [
            "key": .string(row.key), "kind": .string(row.kind.rawValue), "visible": .bool(row.visible),
            "hidden_for": row.hiddenFor.map { JSONValue.number(($0 * 1000).rounded() / 1000) } ?? .null,
            "state": .string(row.state.rawValue), "eligibility": .string(eligibility(row.eligibility)),
            "reason": row.eligibility.reason.map { JSONValue.string($0.rawValue) } ?? .null,
            "last_discard_reason": row.lastDiscardReason.map { JSONValue.string($0.rawValue) } ?? .null,
            "wake_count": JSONValue(row.wakeCount),
        ]
    }

    private static func eligibility(_ result: CanDiscardResult) -> String {
        switch result {
        case .eligible: "eligible"
        case .protected: "protected"
        case .disallowed: "disallowed"
        }
    }
}

package import CmuxNextSettings

/// `debug.discards`: cmux's chrome://discards (chrome/browser/ui/webui/discards/discards_ui.cc).
/// One row per content the planner's owners report, for every ``ContentKind``: its kind, whether
/// it shows, how long it has been hidden, its lifecycle state, whether it can be discarded and why
/// not, its last discard's reason and how often it woke. O(contents tracked). A kind no owner
/// reports yet is listed with the reason `no_policy`. Rows carry tab keys only: no URL, title or path.
extension ContentDiscardPlanner {
    /// The method's answer at `now`. `{"kind": "<kind>"}` keeps one kind.
    package func report(_ params: [String: JSONValue] = [:], now: ContinuousClock.Instant) -> JSONValue {
        var only: ContentKind?
        if let raw = params["kind"]?.stringValue {
            guard let kind = ContentKind(rawValue: raw) else {
                return ["error": .string("kind must be one of \(ContentKind.allCases.map(\.rawValue).joined(separator: ", "))")]
            }
            only = kind
        }
        let listed = self.kinds.filter { only == nil || $0.kind == only }
        let contents = self.rows(now: now).filter { only == nil || $0.kind == only }
        return ["kinds": .array(listed.map(\.json)), "contents": .array(contents.map(\.json))]
    }
}

extension ContentDiscardPlanner.KindSummary {
    /// The kind as `debug.discards` lists it.
    package var json: JSONValue {
        [
            "kind": .string(kind.rawValue), "tracked": .bool(tracked),
            "contents": JSONValue(contents), "discarded": JSONValue(discarded),
            "reason": reason.map { JSONValue.string($0.rawValue) } ?? .null,
        ]
    }
}

extension ContentDiscardPlanner.Row {
    /// The row as `debug.discards` lists it.
    package var json: JSONValue {
        [
            "key": .string(key), "kind": .string(kind.rawValue), "visible": .bool(visible),
            "hidden_for": hiddenFor.map { JSONValue.number(($0 * 1000).rounded() / 1000) } ?? .null,
            "state": .string(state.rawValue), "eligibility": .string(eligibility.name),
            "reason": eligibility.reason.map { JSONValue.string($0.rawValue) } ?? .null,
            "last_discard_reason": lastDiscardReason.map { JSONValue.string($0.rawValue) } ?? .null,
            "wake_count": JSONValue(wakeCount),
        ]
    }
}

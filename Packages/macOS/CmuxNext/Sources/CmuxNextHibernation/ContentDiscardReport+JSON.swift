package import CmuxNextSettings

/// `debug.discards`: cmux's chrome://discards (chrome/browser/ui/webui/discards/discards_ui.cc).
/// The nine ``ContentKind``s (a kind no owner reports yet has the reason `not_a_tab`) and one row
/// per content an owner reports: its kind, whether it shows, how long it has been hidden, its
/// lifecycle state, whether it can be discarded and why not, its last discard's reason and how often
/// it woke. O(contents tracked). Rows carry tab keys only: no URL, title or path, so release builds
/// serve it.
nonisolated extension ContentDiscardReport {
    /// The method's answer at `now`. `{"kind": "<kind>"}` keeps one kind.
    package func report(_ params: [String: JSONValue] = [:], now: ContinuousClock.Instant) -> JSONValue {
        var only: ContentKind?
        if let raw = params["kind"]?.stringValue {
            guard let kind = ContentKind(rawValue: raw) else {
                return ["error": .string("kind must be one of \(ContentKind.allCases.map(\.rawValue).joined(separator: ", "))")]
            }
            only = kind
        }
        let listed = kinds.filter { only == nil || $0.kind == only }
        let contents = rows(now: now).filter { only == nil || $0.kind == only }
        return ["kinds": .array(listed.map(\.json)), "contents": .array(contents.map(\.json))]
    }
}

nonisolated extension ContentDiscardReport.KindSummary {
    /// The kind as `debug.discards` lists it.
    package var json: JSONValue {
        [
            "kind": .string(kind.rawValue), "tracked": .bool(tracked),
            "contents": JSONValue(contents), "discarded": JSONValue(discarded),
            "reason": reason.map { JSONValue.string($0.rawValue) } ?? .null,
        ]
    }
}

nonisolated extension ContentDiscardReport.Row {
    /// The row as `debug.discards` lists it: `reason` is the first of `reasons`, the reason
    /// `debug.surfaces` shows.
    package var json: JSONValue {
        [
            "key": .string(key), "kind": .string(kind.rawValue), "visible": .bool(visible),
            "hidden_for": hiddenFor.map { JSONValue.number(($0 * 1000).rounded() / 1000) } ?? .null,
            "state": .string(state.rawValue), "eligibility": .string(eligibility.result.name),
            "reason": eligibility.reason.map { JSONValue.string($0.rawValue) } ?? .null,
            "reasons": .array(eligibility.reasons.map { .string($0.rawValue) }),
            "last_discard_reason": lastDiscardReason.map { JSONValue.string($0.rawValue) } ?? .null,
            "wake_count": JSONValue(wakeCount),
        ]
    }
}

nonisolated extension CanDiscardResult {
    /// The result's name in `debug.discards`.
    package var name: String {
        switch self {
        case .eligible: "eligible"
        case .protected: "protected"
        case .disallowed: "disallowed"
        }
    }
}

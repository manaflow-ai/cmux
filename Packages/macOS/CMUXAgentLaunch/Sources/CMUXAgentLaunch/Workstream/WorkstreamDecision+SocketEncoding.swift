import Foundation

extension WorkstreamDecision {
    /// The `[String: Any]` JSON shape the `feed.*` socket handlers emit for a
    /// resolved decision. Byte-faithful port of the legacy
    /// `FeedSocketEncoding.decisionDict`.
    public var socketEncodedDictionary: [String: Any] {
        switch self {
        case .permission(let mode):
            return ["kind": "permission", "mode": mode.rawValue]
        case .exitPlan(let mode, let feedback):
            var dict: [String: Any] = ["kind": "exit_plan", "mode": mode.rawValue]
            if let feedback, !feedback.isEmpty {
                dict["feedback"] = feedback
            }
            return dict
        case .question(let selections):
            return ["kind": "question", "selections": selections]
        }
    }
}

import Foundation
import os

/// The app log line of every `transport.intent_invalid` the pane host answers. The page shows that
/// refusal as "Something went wrong, so that didn't go through." and nothing else, so this line is
/// the only place its reason lands: the method, the rule that refused it and a short cause. A
/// refusal path calls ``log(_:method:session:cause:)`` (or the checks' ``AgentPaneTransport/intentInvalid``)
/// rather than writing its own line. Privacy: a cause names fields and rules, never a value, prompt
/// text or token.
nonisolated enum AgentPaneRefusalLog {
    /// The rule that refused the frame or gesture.
    enum Rule: String, Sendable, CaseIterable {
        /// A method's known params, and no daemon mode field outside the setting methods (P1).
        case paramsRule = "params_rule"
        /// `answers` and `annotations` on `_acpmux/permission_respond` go only to a pending question.
        case answersRule = "answers_rule"
        /// A gesture ticket goes with nothing else in `_meta` (R1).
        case gestureMeta = "gesture_meta"
        /// `transport.gesture`'s intent breaks its contract (``AgentPaneGestureIntent``).
        case gestureParse = "gesture_parse"

        /// The rule in the line's words ("params rule" keeps the line cmux#44964 added).
        var words: String { rawValue.replacingOccurrences(of: "_", with: " ") }
    }

    /// The most field names one cause lists, and the most characters of each.
    static let maximumNames = 8
    static let maximumNameLength = 64

    /// One refusal's line, in the format of the params rule's (cmux#44964).
    static func line(_ rule: Rule, method: String?, session: String?, cause: String) -> String {
        "agent pane \(rule.words) refused method=\(method.map(bounded) ?? "-") session=\(session.map(bounded) ?? "none") rule=\(rule.rawValue) cause=\(cause)"
    }

    /// Logs one refusal under `agent-pane.transport`.
    static func log(_ rule: Rule, method: String?, session: String? = nil, cause: String) {
        let text = line(rule, method: method, session: session, cause: cause)
        AgentPaneTransport.logger.error("\(text, privacy: .public)")
    }

    /// Field names for a cause: sorted, at most ``maximumNames``, each at most ``maximumNameLength``
    /// characters.
    static func names(_ keys: some Sequence<String>) -> String {
        let sorted = keys.sorted()
        var shown = sorted.prefix(maximumNames).map(bounded)
        if sorted.count > maximumNames { shown.append("+\(sorted.count - maximumNames)") }
        return "[" + shown.joined(separator: ", ") + "]"
    }

    private static func bounded(_ name: String) -> String {
        name.count > maximumNameLength ? String(name.prefix(maximumNameLength)) + "…" : name
    }
}

extension AgentPaneTransport {
    /// A check's `transport.intent_invalid`, logged (``AgentPaneRefusalLog``) before it is returned.
    nonisolated static func intentInvalid(_ rule: AgentPaneRefusalLog.Rule, method: String?, requestID: String?,
                                          session: String?, cause: String, detail: String? = nil) -> AcpmuxPaneMethods.Decision {
        AgentPaneRefusalLog.log(rule, method: method, session: session, cause: cause)
        return .refuse(.intentInvalid, method: method, requestID: requestID, detail: detail)
    }
}

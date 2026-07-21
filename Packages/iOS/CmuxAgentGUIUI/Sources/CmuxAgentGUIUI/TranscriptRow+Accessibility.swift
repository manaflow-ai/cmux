#if os(iOS)
import CmuxAgentGUIProjection

extension TranscriptRow {
    var accessibilityLabel: String {
        switch rowKind {
        case .proseAgent(let text, _), .streaming(let text):
            AgentGUIL10n.agentAccessibilityLabel(text)
        case .proseUser(let text, _, _):
            AgentGUIL10n.userAccessibilityLabel(text)
        case .attachment(let attachment):
            attachment.displayName ?? attachment.summary
        case .pendingTicket(let ticket):
            AgentGUIL10n.userAccessibilityLabel(ticket.text)
        case .pendingAsk(let ask):
            ask.promptSummary
        case .status(let code, let detail):
            [AgentGUIL10n.statusCode(code), detail].compactMap(\.self).joined(separator: " ")
        case .dateHeader(let dayKey):
            dayKey
        case .boundary:
            AgentGUIL10n.string(
                "agent.transcript.boundary",
                defaultValue: "Earlier history is on your Mac"
            )
        case .hole(let range):
            AgentGUIL10n.hole(
                lowerBound: range.lowerBound.rawValue,
                upperBound: range.upperBound.rawValue
            )
        case .genericActivity(let activity):
            "\(AgentGUIL10n.activityKind(activity.kindLabel)) \(activity.summary)"
        case .activitySummary(let summary):
            AgentGUIL10n.activitySummary(summary)
        case .activityItem(let item):
            AgentGUIL10n.activityAccessibility(item)
        case .unsupported(let rawKind, let summary):
            "\(rawKind) \(summary)"
        }
    }
}
#endif

#if os(iOS)
import CmuxAgentGUIProjection

extension TranscriptRow {
    var accessibilityLabel: String {
        switch rowKind {
        case .proseAgent(let text, _), .streaming(let text):
            AgentGUIL10n.agentAccessibilityLabel(text)
        case .proseUser(let text, _, _, let attachmentCount, let hasImage):
            [
                AgentGUIL10n.userAccessibilityLabel(text),
                max(attachmentCount, hasImage ? 1 : 0) > 0
                    ? AgentGUIL10n.attachmentCount(max(attachmentCount, hasImage ? 1 : 0))
                    : nil,
                hasImage ? AgentGUIL10n.string(
                    "agent.transcript.attachment.includesImage",
                    defaultValue: "Includes image"
                ) : nil,
            ].compactMap(\.self).joined(separator: ", ")
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
        case .hole:
            AgentGUIL10n.hole()
        case .genericActivity(let activity):
            "\(AgentGUIL10n.activityKind(activity.kindLabel)) \(activity.summary)"
        case .activitySummary(let summary):
            AgentGUIL10n.activitySummary(summary)
        case .activityItem(let item):
            AgentGUIL10n.activityAccessibility(item)
        case .unsupported(_, let summary):
            [
                AgentGUIL10n.string("agent.activity.event", defaultValue: "Event"),
                summary,
            ].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}
#endif

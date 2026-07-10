#if os(iOS)
import CmuxAgentGUIProjection

extension TranscriptRow {
    var measurementContentHash: Int {
        var hasher = Hasher()
        hasher.combine(measurementText)
        hasher.combine(isProse)
        return hasher.finalize()
    }

    var measurementText: String {
        switch rowKind {
        case .proseAgent(let text, _), .proseUser(let text, _, _), .streaming(let text):
            text
        case .status(let code, let detail):
            [AgentGUIL10n.statusCode(code), detail].compactMap(\.self).joined(separator: " ")
        case .dateHeader(let dayKey):
            dayKey
        case .boundary:
            AgentGUIL10n.string("agent.transcript.boundary", defaultValue: "Earlier history is on your Mac")
        case .hole(let range):
            AgentGUIL10n.hole(
                lowerBound: range.lowerBound.rawValue,
                upperBound: range.upperBound.rawValue
            )
        case .pendingTicket(let ticket):
            ticket.text
        case .genericActivity(let activity):
            "\(AgentGUIL10n.activityKind(activity.kindLabel)) \(activity.summary)"
        case .unsupported(let rawKind, let summary):
            "\(rawKind) \(summary)"
        }
    }

    var accessibilityLabel: String {
        switch rowKind {
        case .proseAgent(let text, _), .streaming(let text):
            AgentGUIL10n.agentAccessibilityLabel(text)
        case .proseUser(let text, _, _):
            AgentGUIL10n.userAccessibilityLabel(text)
        case .pendingTicket(let ticket):
            AgentGUIL10n.userAccessibilityLabel(ticket.text)
        case .status, .dateHeader, .boundary, .hole, .genericActivity, .unsupported:
            measurementText
        }
    }

    var isProse: Bool {
        switch rowKind {
        case .proseAgent, .proseUser, .pendingTicket, .streaming:
            true
        case .status, .dateHeader, .boundary, .hole, .genericActivity, .unsupported:
            false
        }
    }
}
#endif

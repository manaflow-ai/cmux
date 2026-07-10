import CmuxAgentReplica
import Foundation

enum AgentGUIL10n {
    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    static func unreadValue(_ count: Int) -> String {
        if count == 1 {
            return string("agent.transcript.pill.unread.one", defaultValue: "1 unread")
        }
        return String(
            format: string("agent.transcript.pill.unread.other", defaultValue: "%d unread"),
            count
        )
    }

    static func rowsPerSecond(_ count: Int) -> String {
        String(format: string("agent.demo.speedFormat", defaultValue: "%d rows/s"), count)
    }

    static func activityKind(_ kind: String) -> String {
        switch kind.lowercased() {
        case "command": string("agent.activity.command", defaultValue: "Command")
        case "tool": string("agent.activity.tool", defaultValue: "Tool")
        case "file": string("agent.activity.file", defaultValue: "File")
        case "question": string("agent.activity.question", defaultValue: "Question")
        case "permission": string("agent.activity.permission", defaultValue: "Permission")
        case "thought": string("agent.activity.thought", defaultValue: "Thought")
        default: kind
        }
    }

    static func statusCode(_ code: StatusCode) -> String {
        switch code {
        case .compacted: string("agent.status.compacted", defaultValue: "Context compacted")
        case .turnAborted: string("agent.status.turnAborted", defaultValue: "Turn aborted")
        case .apiError: string("agent.status.apiError", defaultValue: "API error")
        case .sessionMeta: string("agent.status.sessionMeta", defaultValue: "Session updated")
        case .other(let rawValue): rawValue
        }
    }

    static func hole(lowerBound: Int, upperBound: Int) -> String {
        String(
            format: string("agent.transcript.holeFormat", defaultValue: "Missing entries %lld-%lld"),
            Int64(lowerBound),
            Int64(upperBound)
        )
    }

    static func agentAccessibilityLabel(_ text: String) -> String {
        String(
            format: string("agent.transcript.accessibility.agent", defaultValue: "Agent: %@"),
            text
        )
    }

    static func userAccessibilityLabel(_ text: String) -> String {
        String(
            format: string("agent.transcript.accessibility.user", defaultValue: "You: %@"),
            text
        )
    }
}

import CmuxAgentReplica
import CmuxAgentGUIProjection
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
        default: string("agent.activity.event", defaultValue: "Event")
        }
    }

    static func activityKind(_ kind: TranscriptActivityKind) -> String {
        switch kind {
        case .assistant: string("agent.activity.assistant", defaultValue: "Assistant")
        case .thought: string("agent.activity.thought", defaultValue: "Thought")
        case .command: string("agent.activity.command", defaultValue: "Command")
        case .tool: string("agent.activity.tool", defaultValue: "Tool")
        case .file: string("agent.activity.file", defaultValue: "File")
        case .question: string("agent.activity.question", defaultValue: "Question")
        case .permission: string("agent.activity.permission", defaultValue: "Permission")
        case .status: string("agent.activity.status", defaultValue: "Status")
        case .attachment: string("agent.activity.attachment", defaultValue: "Attachment")
        case .unknown: string("agent.activity.event", defaultValue: "Event")
        }
    }

    static func activityAccessibility(_ item: TranscriptActivityItem) -> String {
        [
            activityKind(item.kind),
            activityDetail(item),
            item.isFailed ? string("agent.activity.failed", defaultValue: "Failed") : nil,
        ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func activityDetail(_ item: TranscriptActivityItem) -> String {
        var parts = [item.summary].filter { !$0.isEmpty }
        if let exitCode = item.exitCode {
            parts.append(String(
                format: string("agent.activity.exitCode", defaultValue: "Exit %d"),
                exitCode
            ))
        }
        return parts.joined(separator: " · ")
    }

    static func activitySummary(_ summary: TranscriptActivitySummary) -> String {
        var parts = [String]()
        if summary.editedFileCount > 0 {
            parts.append(activityCount(
                summary.editedFileCount,
                oneKey: "agent.activity.summary.edited.one",
                oneDefault: "Edited 1 file",
                otherKey: "agent.activity.summary.edited.other",
                otherDefault: "Edited %d files"
            ))
        }
        if summary.readFileCount > 0 {
            parts.append(activityCount(
                summary.readFileCount,
                oneKey: "agent.activity.summary.read.one",
                oneDefault: "Read 1 file",
                otherKey: "agent.activity.summary.read.other",
                otherDefault: "Read %d files"
            ))
        }
        if summary.searchedCode {
            parts.append(string("agent.activity.summary.searched", defaultValue: "Searched code"))
        }
        if summary.listedFiles {
            parts.append(string("agent.activity.summary.listed", defaultValue: "Listed files"))
        }
        if summary.commandCount > 0 {
            parts.append(activityCount(
                summary.commandCount,
                oneKey: "agent.activity.summary.command.one",
                oneDefault: "Ran 1 command",
                otherKey: "agent.activity.summary.command.other",
                otherDefault: "Ran %d commands"
            ))
        }
        if summary.commandCount == 0, summary.eventCount > 0 {
            parts.append(activityCount(
                summary.eventCount,
                oneKey: "agent.activity.summary.event.one",
                oneDefault: "Processed 1 event",
                otherKey: "agent.activity.summary.event.other",
                otherDefault: "Processed %d events"
            ))
        }
        if summary.failedCount > 0 {
            parts.append(activityCount(
                summary.failedCount,
                oneKey: "agent.activity.summary.failed.one",
                oneDefault: "1 failed",
                otherKey: "agent.activity.summary.failed.other",
                otherDefault: "%d failed"
            ))
        }
        return parts.isEmpty
            ? string("agent.activity.summary.none", defaultValue: "No activity")
            : parts.formatted(.list(type: .and))
    }

    private static func activityCount(
        _ count: Int,
        oneKey: StaticString,
        oneDefault: String.LocalizationValue,
        otherKey: StaticString,
        otherDefault: String.LocalizationValue
    ) -> String {
        guard count != 1 else {
            return string(oneKey, defaultValue: oneDefault)
        }
        return String(format: string(otherKey, defaultValue: otherDefault), count)
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

    static func hole() -> String {
        string("agent.transcript.hole", defaultValue: "Syncing earlier messages…")
    }

    static func attachmentCount(_ count: Int) -> String {
        activityCount(
            count,
            oneKey: "agent.transcript.attachment.one",
            oneDefault: "1 attachment",
            otherKey: "agent.transcript.attachment.other",
            otherDefault: "%d attachments"
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

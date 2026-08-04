import CmuxAgentReplica
import Foundation

extension TranscriptProjector {
    static func activityItem(_ context: EntryContext) -> TranscriptActivityItem {
        let entry = context.entry
        let id = TranscriptRowID.entry(journalID: entry.journalID, seq: entry.seq)
        return switch entry.content.payload {
        case .userMessage(let payload):
            TranscriptActivityItem(id: id, kind: .unknown, summary: payload.text, isRunning: false)
        case .agentProse(let payload):
            TranscriptActivityItem(id: id, kind: .assistant, summary: payload.markdown, isRunning: false)
        case .thought(let payload):
            TranscriptActivityItem(id: id, kind: .thought, summary: payload.text, isRunning: false)
        case .toolRun(let payload):
            TranscriptActivityItem(
                id: id,
                kind: payload.isTerminal ? .command : .tool,
                summary: joined([payload.toolName, payload.argumentSummary, payload.resultSummary]),
                isRunning: payload.isRunning,
                exitCode: payload.exitCode,
                isFailed: payload.exitCode.map { $0 != 0 } == true
            )
        case .fileChange(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .file,
                summary: joined([payload.changeKind.rawValue, payload.path, payload.resultSummary]),
                isRunning: false
            )
        case .question(let payload):
            TranscriptActivityItem(id: id, kind: .question, summary: payload.prompt, isRunning: false)
        case .permission(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .permission,
                summary: joined([payload.toolName, payload.detail]),
                isRunning: false
            )
        case .status(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .status,
                summary: joined([payload.detail]),
                isRunning: false,
                isFailed: isFailedStatus(payload.code)
            )
        case .attachment(let payload):
            TranscriptActivityItem(id: id, kind: .attachment, summary: payload.summary, isRunning: false)
        case .unknown(let payload):
            TranscriptActivityItem(
                id: id,
                kind: .unknown,
                summary: payload.summary ?? "",
                isRunning: false
            )
        }
    }

    static func activitySummary(items: [TranscriptActivityItem]) -> TranscriptActivitySummary {
        var fileEditCount = 0
        var toolEditCount = 0
        var readFileCount = 0
        var searchedCode = false
        var listedFiles = false
        var commandCount = 0
        var eventCount = 0
        for item in items {
            switch item.kind {
            case .file:
                fileEditCount += 1
            case .tool, .command:
                commandCount += 1
                let tokens = Set(item.summary.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                if !tokens.isDisjoint(with: ["read", "cat", "sed", "nl", "open"]) { readFileCount += 1 }
                if !tokens.isDisjoint(with: ["rg", "grep", "search"]) { searchedCode = true }
                if !tokens.isDisjoint(with: ["ls", "find", "list"]) { listedFiles = true }
                if !tokens.isDisjoint(with: ["edit", "write", "apply_patch", "patch"]) { toolEditCount += 1 }
            case .assistant:
                break
            case .thought, .question, .permission, .attachment:
                eventCount += 1
            case .status:
                if item.isFailed { eventCount += 1 }
            case .unknown:
                break
            }
        }
        return TranscriptActivitySummary(
            editedFileCount: max(fileEditCount, toolEditCount),
            readFileCount: readFileCount,
            searchedCode: searchedCode,
            listedFiles: listedFiles,
            commandCount: commandCount,
            eventCount: eventCount,
            failedCount: items.filter(\.isFailed).count,
            items: items
        )
    }

    static func isMeaningfulActivity(_ item: TranscriptActivityItem) -> Bool {
        switch item.kind {
        case .thought, .command, .tool, .file, .question, .permission, .attachment:
            true
        case .status:
            item.isFailed
        case .assistant, .unknown:
            false
        }
    }

    private static func isFailedStatus(_ code: StatusCode) -> Bool {
        switch code {
        case .apiError, .turnAborted:
            true
        case .compacted, .sessionMeta, .other:
            false
        }
    }

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { part in
            let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.joined(separator: " · ")
    }
}

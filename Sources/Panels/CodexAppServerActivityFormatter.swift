import Foundation

/// Pure parser that turns Codex app-server wire-JSON items into the activity
/// attributes (status, action label, command/file-change detail) and the user
/// facing message strings the session forwards to its sinks.
///
/// This is a stateless value type held by `CodexAppServerSession`. It owns no
/// session state: every method is a pure transform over the decoded JSON it is
/// handed, so it can be exercised in isolation. The localized labels are
/// resolved with `String(localized:)` here in the app target, where the keys in
/// `Resources/Localizable.xcstrings` resolve; keeping the formatter app-side
/// preserves the Japanese (and every non-English) translation.
struct CodexAppServerActivityFormatter: Sendable {
    /// Whether a Codex item represents an assistant/agent message (vs a tool item).
    func itemIsAgentMessage(_ item: [String: Any]) -> Bool {
        guard let itemType = item["type"] as? String else { return false }
        switch itemType {
        case "agentMessage", "assistantMessage", "message":
            return true
        default:
            return false
        }
    }

    /// Normalizes a Codex item's execution/parsed status into the activity status vocabulary.
    func activityStatus(from item: [String: Any], defaultStatus: String) -> String {
        if let parsedCommand = item["parsedCmd"] as? [String: Any],
           let isFinished = parsedCommand["isFinished"] as? Bool,
           !isFinished {
            return "inProgress"
        }
        let rawStatus = (item["executionStatus"] as? String) ?? (item["status"] as? String)
        switch rawStatus?.lowercased() {
        case "interrupted", "canceled", "cancelled", "stopped", "declined", "denied", "rejected":
            return "stopped"
        case "failed", "failure", "error":
            return "failed"
        case "inprogress", "in_progress", "running", "started":
            return "inProgress"
        case "completed", "complete", "succeeded", "success":
            return "completed"
        default:
            return defaultStatus
        }
    }

    /// Localized verb for a command activity given its status.
    func commandAction(status: String) -> String {
        switch status {
        case "inProgress":
            return String(localized: "agentSession.codex.activity.command.running", defaultValue: "Running")
        case "stopped":
            return String(localized: "agentSession.codex.activity.command.stopped", defaultValue: "Stopped")
        default:
            return String(localized: "agentSession.codex.activity.command.ran", defaultValue: "Ran")
        }
    }

    /// Best-effort command text from a Codex command-execution item.
    func commandText(from item: [String: Any]) -> String? {
        if let parsedCommand = item["parsedCmd"] as? [String: Any] {
            for key in ["cmd", "command", "name"] {
                if let value = nonEmptyString(parsedCommand[key]) {
                    return value
                }
            }
        }
        for key in ["command", "cmd", "commandText", "name"] {
            if let value = nonEmptyString(item[key]) {
                return value
            }
        }
        if let command = item["command"] as? [Any] {
            let text = command.compactMap { $0 as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// Localized verb for a file-change activity given its change type and status.
    func fileChangeAction(changeType: String?, status: String) -> String {
        switch (changeType, status) {
        case ("add", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.creating", defaultValue: "Creating")
        case ("add", _):
            return String(localized: "agentSession.codex.activity.file.created", defaultValue: "Created")
        case ("delete", "inProgress"):
            return String(localized: "agentSession.codex.activity.file.deleting", defaultValue: "Deleting")
        case ("delete", _):
            return String(localized: "agentSession.codex.activity.file.deleted", defaultValue: "Deleted")
        case (_, "inProgress"):
            return String(localized: "agentSession.codex.activity.file.editing", defaultValue: "Editing")
        case (_, "stopped"):
            return String(localized: "agentSession.codex.activity.command.stopped", defaultValue: "Stopped")
        default:
            return String(localized: "agentSession.codex.activity.file.edited", defaultValue: "Edited")
        }
    }

    /// Extracts the primary changed path and its change type from a Codex file-change payload.
    func fileChangeSummary(from value: Any?) -> (path: String?, changeType: String?) {
        if let changes = value as? [String: Any] {
            for key in changes.keys.sorted() {
                let change = changes[key] as? [String: Any]
                return (key, fileChangeType(from: change))
            }
        }
        if let changes = value as? [[String: Any]],
           let first = changes.first {
            let path = nonEmptyString(first["path"]) ?? nonEmptyString(first["filePath"]) ?? nonEmptyString(first["name"])
            return (path, fileChangeType(from: first))
        }
        return (nil, nil)
    }

    /// Resolves the change type (add/delete/etc.) from a single file-change entry.
    func fileChangeType(from change: [String: Any]?) -> String? {
        guard let change else { return nil }
        if let type = nonEmptyString(change["type"]) {
            return type
        }
        if let kind = change["kind"] as? [String: Any] {
            return nonEmptyString(kind["type"])
        }
        return nonEmptyString(change["kind"])
    }

    /// Returns a trimmed non-empty string from a JSON value, or nil.
    func nonEmptyString(_ value: Any?) -> String? {
        let string: String?
        if let value = value as? String {
            string = value
        } else {
            string = nil
        }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Pulls a human-readable message out of a Codex notification's params.
    func codexMessage(from params: [String: Any]?) -> String? {
        if let message = params?["message"] as? String {
            return message
        }
        if let warning = params?["warning"] as? String {
            return warning
        }
        if let error = params?["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    /// Localized fallback shown when a Codex app-server RPC fails.
    func rpcFailedMessage() -> String {
        String(localized: "agentSession.codex.error.rpcFailed", defaultValue: "Codex app-server request failed.")
    }

    /// Localized fallback shown for an unrecognized Codex warning.
    func unknownWarningMessage() -> String {
        String(localized: "agentSession.codex.warning.unknown", defaultValue: "Codex app-server reported a warning.")
    }
}

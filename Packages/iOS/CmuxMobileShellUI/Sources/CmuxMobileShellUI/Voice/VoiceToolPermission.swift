import Foundation

/// Permission tier of one orchestrator tool.
///
/// - `read`: observes state, always allowed.
/// - `act`: mutates state in a recoverable way; the voice layer confirms
///   verbally per its instructions, and the app executes immediately.
/// - `destructive`: hard to undo. Execution stops on an on-screen approval
///   card unless the user enabled Bypass All Permissions in Settings, so
///   spoken misrecognition alone can never destroy work.
public enum VoiceToolPermission: Sendable, Equatable {
    case read
    case act
    case destructive
}

/// Static tool metadata shared by the executor, the session controller's
/// approval gate, and tests. Kept dependency-free so the classification is
/// trivially unit-testable.
public enum VoiceToolCatalog {
    public static func permission(forTool name: String) -> VoiceToolPermission {
        switch name {
        case "list_workspaces", "read_workspace", "read_agent_messages",
             "read_notifications", "list_computers", "read_workspace_changes":
            return .read
        case "close_workspace":
            return .destructive
        default:
            // Unknown names execute as .act: the executor answers them with
            // "Unknown tool", which is harmless, and a future read-only tool
            // misclassified as act only costs a verbal confirmation.
            return .act
        }
    }

    /// Short human-readable description of a destructive call for the
    /// approval card. `nil` falls back to the generic template.
    public static func approvalSummary(
        forTool name: String,
        argumentsJSON: String
    ) -> String? {
        guard name == "close_workspace" else { return nil }
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any]
        guard let workspace = arguments?["workspace"] as? String, !workspace.isEmpty else {
            return nil
        }
        return workspace
    }
}

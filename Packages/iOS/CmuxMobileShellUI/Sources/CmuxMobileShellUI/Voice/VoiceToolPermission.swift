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
             "read_notifications", "list_computers", "read_workspace_changes",
             "list_memories":
            return .read
        // type_in_terminal is destructive alongside close_workspace: raw
        // text plus Return into a shell is arbitrary command execution, the
        // sharpest prompt-injection edge the orchestrator has. Agent-directed
        // tools (send_prompt, create_task) stay .act because coding agents
        // run their own permission systems.
        case "close_workspace", "type_in_terminal":
            return .destructive
        default:
            // Unknown names execute as .act: the executor answers them with
            // "Unknown tool", which is harmless, and a future read-only tool
            // misclassified as act only costs a verbal confirmation.
            return .act
        }
    }
}

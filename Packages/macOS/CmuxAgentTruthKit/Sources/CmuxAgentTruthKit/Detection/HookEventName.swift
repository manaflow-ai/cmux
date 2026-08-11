import Foundation

/// Describes normalized hook event names while preserving unknown raw values.
public enum HookEventName: Hashable, Sendable {
    /// The agent announced a session start.
    case sessionStart
    /// The user submitted a prompt.
    case userPromptSubmit
    /// A tool is about to run.
    case preToolUse
    /// A tool finished.
    case postToolUse
    /// The agent requested permission.
    case permissionRequest
    /// The agent emitted a notification.
    case notification
    /// The parent agent completed a response.
    case stop
    /// A subagent completed a response.
    case subagentStop
    /// The agent announced session end.
    case sessionEnd
    /// An unrecognized hook event.
    case unknown(String)

    /// Creates a normalized hook event from a raw hook name.
    /// - Parameter rawValue: The raw event name.
    public init(rawValue: String) {
        switch rawValue {
        case "SessionStart", "session_start": self = .sessionStart
        case "UserPromptSubmit", "user_prompt_submit": self = .userPromptSubmit
        case "PreToolUse", "pre_tool_use", "beforeShellExecution": self = .preToolUse
        case "PostToolUse", "post_tool_use": self = .postToolUse
        case "PermissionRequest", "permission_request": self = .permissionRequest
        case "Notification", "notification": self = .notification
        case "Stop", "stop": self = .stop
        case "SubagentStop", "subagent_stop": self = .subagentStop
        case "SessionEnd", "session_end": self = .sessionEnd
        default: self = .unknown(rawValue)
        }
    }
}

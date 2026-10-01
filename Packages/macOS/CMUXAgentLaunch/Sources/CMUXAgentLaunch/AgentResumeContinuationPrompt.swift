import Foundation

/// Adds a one-shot prompt to a resume argv so the resumed agent continues its interrupted turn.
///
/// The prompt goes right after the resumed session id, ahead of the preserved launch options, so
/// no captured option (a variadic or optional-value flag) can take it as its value:
/// - claude: `claude --resume <id> <prompt> ...`
/// - codex: `codex resume <id> <prompt> ...` (`codex resume [SESSION_ID] [PROMPT]`)
/// - opencode: `opencode --session <id> --prompt <prompt> ...`
///
/// Launch captures strip prompts on purpose (``AgentLaunchSanitizer``), so a later resume of the
/// same session does not repeat it.
struct AgentResumeContinuationPrompt {
    let prompt: String

    /// Returns `arguments` with the prompt inserted, or `nil` when `kind` takes no resume prompt
    /// or `arguments` does not resume `sessionID` the way that kind does.
    func applying(to arguments: [String], kind: String, sessionID: String) -> [String]? {
        let resumeMarker: String
        let promptTokens: [String]
        switch kind {
        case "claude":
            resumeMarker = "--resume"
            promptTokens = [prompt]
        case "codex":
            resumeMarker = "resume"
            promptTokens = [prompt]
        case "opencode":
            resumeMarker = "--session"
            promptTokens = ["--prompt", prompt]
        default:
            return nil
        }
        guard let markerIndex = arguments.indices.dropLast().first(where: {
            arguments[$0] == resumeMarker && arguments[$0 + 1] == sessionID
        }) else {
            return nil
        }
        var result = arguments
        result.insert(contentsOf: promptTokens, at: markerIndex + 2)
        return result
    }
}

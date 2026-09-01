import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let completionProof = AgentHookCompletionProof()

    /// Returns true only when Claude's Stop payload contains a usable assistant
    /// message that is not itself a known provider-failure banner. Claude Code
    /// normally sends `last_assistant_message` for a successful turn, but some
    /// provider refusals and quota responses are echoed there as well. Treating
    /// those strings as a normal completion would suppress the PTY classifier
    /// at precisely the boundary where it needs to act.
    func claudeHookProvesNormalCompletion(
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        Self.completionProof.provesNormalCompletion(
            provider: "claude",
            assistantMessage: assistantMessage,
            payload: payload
        )
    }

    /// Returns true only when a Codex stop payload proves a healthy assistant
    /// response. Codex can echo a safeguard or quota banner as
    /// `last_assistant_message` without emitting a transcript `error` event,
    /// so the same conservative proof used for Claude is required before the
    /// app suppresses PTY classification.
    func codexHookProvesNormalCompletion(
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        Self.completionProof.provesNormalCompletion(
            provider: "codex",
            assistantMessage: assistantMessage,
            payload: payload
        )
    }
}

import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// How a `claude_account.switch` socket request ended.
enum ClaudeAccountSwitchSocketOutcome: Equatable, Sendable {
    /// The request reached the switch, or was refused with a switch result before it (an
    /// account name the pane's registry does not know).
    case finished(ClaudeAccountSwitchResult)
    /// Claude is mid-response in the pane and the request did not pass `force`; nothing changed.
    case agentRunning

    /// The socket reply for this outcome. This is the one place a switch result becomes a
    /// socket error code; the CLI prints what it receives.
    ///
    /// A switch whose resume was never typed still succeeds, with `resumed: false` and the
    /// built `resume_command` for the caller to run. Refusals carry the same explanation the
    /// menu and the command palette show.
    ///
    /// - Parameters:
    ///   - surfaceId: The pane the request named.
    ///   - requestedAccountName: The account the request asked for, named by results that
    ///     carry no plan.
    func controlCallResult(surfaceId: UUID, requestedAccountName: String) -> ControlCallResult {
        let result: ClaudeAccountSwitchResult
        switch self {
        case .agentRunning:
            return .err(
                code: "agent_running",
                message: String(
                    localized: "socket.claudeAccountSwitch.agentRunning",
                    defaultValue: "Claude is responding in this terminal. Retry with force to stop the response and switch."
                ),
                data: Self.errorData(surfaceId: surfaceId)
            )
        case .finished(let finished):
            result = finished
        }

        let code: String
        switch result {
        case .switched(let plan, let transcript):
            return .ok(Self.switchedPayload(plan: plan, transcript: transcript, surfaceId: surfaceId, manualResume: nil))
        case .switchedWithoutResume(let plan, let transcript, let manualResume):
            return .ok(Self.switchedPayload(
                plan: plan,
                transcript: transcript,
                surfaceId: surfaceId,
                manualResume: manualResume
            ))
        case .refused(.unknownAccount):
            code = "unknown_account"
        case .refused(.sameAccount):
            code = "same_account"
        case .refused(.noClaudeSession):
            code = "no_claude_session"
        case .refused(.missingWorkingDirectory):
            code = "missing_working_directory"
        case .notClaude:
            code = "not_claude"
        case .remoteUnsupported:
            code = "remote_unsupported"
        case .alreadySwitching:
            code = "already_switching"
        case .transcriptUnavailable:
            code = "transcript_unavailable"
        case .respawnFailed:
            code = "respawn_failed"
        }
        return .err(
            code: code,
            message: ClaudeAccountSwitchNotice(result: result, requestedAccountName: requestedAccountName)?
                .message ?? code,
            data: Self.errorData(surfaceId: surfaceId)
        )
    }

    private static func switchedPayload(
        plan: ClaudeAccountSwitchPlan,
        transcript: ClaudeTranscriptAccountSyncOutcome,
        surfaceId: UUID,
        manualResume: ClaudeAccountSwitchManualResume?
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "surface_id": .string(surfaceId.uuidString),
            "session_id": .string(plan.sessionID),
            "from": .string(plan.source.name),
            "to": .string(plan.target.name),
            "transcript": .string(transcript.rawValue),
            "resumed": .bool(manualResume == nil),
        ]
        if let manualResume {
            payload["resume_command"] = .string(manualResume.command)
            payload["pane_closed"] = .bool(manualResume.paneWasReplaced)
        }
        return .object(payload)
    }

    private static func errorData(surfaceId: UUID) -> JSONValue {
        .object(["surface_id": .string(surfaceId.uuidString)])
    }
}

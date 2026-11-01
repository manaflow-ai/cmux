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
        case .refused(.noConversationYet):
            code = "no_conversation_yet"
        case .refused(.transcriptDiverged):
            code = "transcript_diverged"
        case .notClaude:
            code = "not_claude"
        case .remoteUnsupported:
            code = "remote_unsupported"
        case .agentNotOwnedByPane:
            code = "agent_not_owned_by_pane"
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

    /// A cmux notification the socket path posts with its reply.
    struct ResumeNotification: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String

        /// Posts once: on the pane while it is still there, otherwise on its workspace. Delivery
        /// goes through the notification store only, so it never activates the app or moves focus.
        ///
        /// Whether the pane is there is asked up front, never read from `deliver`'s result: with
        /// notification hooks configured, recording is deferred and returns no id even for a live
        /// pane, and a workspace-level retry would show the notification twice.
        ///
        /// - Parameters:
        ///   - paneIsLive: Whether a notification on `panelId` can still reach its pane.
        ///   - deliver: Records one notification and returns its id, or `nil` when nothing was
        ///     recorded yet (a deferred delivery, an unknown target or a muted workspace).
        @MainActor
        @discardableResult
        func post(
            workspaceId: UUID,
            panelId: UUID,
            paneIsLive: Bool,
            deliver: (_ workspaceId: UUID, _ surfaceId: UUID?, _ title: String, _ subtitle: String, _ body: String) -> UUID?
        ) -> UUID? {
            deliver(workspaceId, paneIsLive ? panelId : nil, title, subtitle, body)
        }
    }

    /// The notification to post for this outcome: only a switch whose resume was never typed
    /// gets one. Its reply may never be read, because the CLI that asked can run in the very
    /// pane the switch respawned and die with it, so the notification carries the built
    /// command too. The wording is the menu notice's.
    var resumeNotification: ResumeNotification? {
        guard case .finished(let result) = self,
              case .switchedWithoutResume(let plan, _, _) = result,
              let notice = ClaudeAccountSwitchNotice(result: result, requestedAccountName: plan.target.name) else {
            return nil
        }
        return ResumeNotification(
            title: String(
                localized: "notification.claudeAccountSwitch.title",
                defaultValue: "Claude account switched"
            ),
            subtitle: notice.title,
            body: notice.notificationMessage
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
            payload["not_resumed_reason"] = .string(Self.notResumedReason(manualResume.reason))
        }
        return .object(payload)
    }

    /// Why the resume was not typed, as the socket names it.
    private static func notResumedReason(_ reason: ClaudeAccountSwitchManualResume.Reason) -> String {
        switch reason {
        case .paneReplaced:
            return "pane_closed"
        case .notTyped:
            return "no_prompt"
        case .previousClaudeStillRunning:
            return "previous_claude_running"
        }
    }

    private static func errorData(surfaceId: UUID) -> JSONValue {
        .object(["surface_id": .string(surfaceId.uuidString)])
    }
}

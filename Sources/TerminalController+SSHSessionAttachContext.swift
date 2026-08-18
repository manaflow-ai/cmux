import CmuxControlSocket
import Foundation

/// Resolves SSH PTY attach ownership through the same persisted-session payload
/// used by `workspace.remote.pty_sessions`.
extension TerminalController {
    nonisolated func v2SSHSessionAttachResolve(params: [String: Any]) -> V2CallResult {
        guard let sessionID = (params["session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "ssh-session-attach requires --session-id <id>",
                data: nil
            )
        }
        let workspaceSelection = v2RequestedRemotePTYWorkspaceID(params: params)
        if let error = workspaceSelection.error { return error }
        let registryResult = v2WorkspaceRemotePTYSessions(params: ["all_workspaces": true])
        return sshSessionAttachV2Result(
            sessionID: sessionID,
            requestedWorkspaceID: workspaceSelection.workspaceId,
            registryResult: registryResult
        )
    }

    private nonisolated func sshSessionAttachV2Result(
        sessionID: String,
        requestedWorkspaceID: UUID?,
        registryResult: V2CallResult
    ) -> V2CallResult {
        guard case .ok(let rawPayload) = registryResult,
              let payload = rawPayload as? [String: Any] else {
            return .err(
                code: "unavailable",
                message: sshSessionAttachStateUnavailableMessage(),
                data: ["session_id": sessionID]
            )
        }

        let matchingWorkspaceIDs = matchingSSHSessionWorkspaceIDs(
            sessionID: sessionID,
            payload: payload
        )
        guard !matchingWorkspaceIDs.isEmpty else {
            // An absent session is still an invalid attach target even when a
            // different remote workspace was unavailable during the inventory
            // read. Keep the error actionable and point callers to the complete
            // cross-workspace listing command.
            return .err(
                code: "not_found",
                message: sshSessionAttachNotFoundMessage(sessionID: sessionID),
                data: ["session_id": sessionID]
            )
        }

        if let requestedWorkspaceID,
           !matchingWorkspaceIDs.contains(requestedWorkspaceID) {
            let owningWorkspaceID = matchingWorkspaceIDs.sorted { $0.uuidString < $1.uuidString }[0]
            return .err(
                code: "invalid_params",
                message: sshSessionAttachWorkspaceMismatchMessage(
                    sessionID: sessionID,
                    owningWorkspaceID: owningWorkspaceID
                ),
                data: [
                    "session_id": sessionID,
                    "owning_workspace_id": owningWorkspaceID.uuidString,
                ]
            )
        }

        guard matchingWorkspaceIDs.count == 1,
              let workspaceID = matchingWorkspaceIDs.first else {
            return .err(
                code: "unavailable",
                message: sshSessionAttachStateUnavailableMessage(),
                data: ["session_id": sessionID]
            )
        }
        return .ok([
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
        ])
    }

    private nonisolated func matchingSSHSessionWorkspaceIDs(
        sessionID: String,
        payload: [String: Any]
    ) -> Set<UUID> {
        let sessions = payload["sessions"] as? [[String: Any]] ?? []
        return Set(
            sessions.compactMap { session -> UUID? in
                guard let candidate = (session["session_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      candidate == sessionID,
                      let rawWorkspaceID = session["workspace_id"] as? String else {
                    return nil
                }
                return UUID(uuidString: rawWorkspaceID)
            }
        )
    }

    private nonisolated func sshSessionAttachNotFoundMessage(sessionID: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "cli.error.sshSessionAttachSessionNotFound",
                defaultValue: "ssh-session-attach: no persisted SSH PTY session with id '%@'. Run 'cmux ssh-session-list --all-workspaces' to see valid session ids."
            ),
            sessionID
        )
    }

    private nonisolated func sshSessionAttachWorkspaceMismatchMessage(
        sessionID: String,
        owningWorkspaceID: UUID
    ) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "cli.error.sshSessionAttachWorkspaceMismatch",
                defaultValue: "ssh-session-attach: session '%1$@' belongs to workspace %2$@, but --workspace requested a different workspace"
            ),
            sessionID,
            owningWorkspaceID.uuidString
        )
    }

    private nonisolated func sshSessionAttachStateUnavailableMessage() -> String {
        String(
            localized: "cli.error.sshSessionAttachStateUnavailable",
            defaultValue: "ssh-session-attach: persisted SSH PTY session state is unavailable"
        )
    }
}

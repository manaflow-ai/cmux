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
            let inventoryErrors = payload["errors"] as? [[String: Any]] ?? []
            if !inventoryErrors.isEmpty,
               let inferredWorkspaceID = Workspace.parsedDefaultSSHPTYSessionID(sessionID)?.workspaceId,
               case .ok(let scopedRawPayload) = v2WorkspaceRemotePTYSessions(
                   params: ["workspace_id": inferredWorkspaceID.uuidString]
               ),
               let scopedPayload = scopedRawPayload as? [String: Any] {
                let scopedMatches = matchingSSHSessionWorkspaceIDs(
                    sessionID: sessionID,
                    payload: scopedPayload
                )
                if !scopedMatches.isEmpty {
                    return sshSessionAttachOwnerResult(
                        sessionID: sessionID,
                        requestedWorkspaceID: requestedWorkspaceID,
                        owningWorkspaceIDs: scopedMatches
                    )
                }
            }

            // A partial inventory cannot prove that the session is unknown.
            // Report unavailable so callers can retry after the remote
            // workspace reconnects; a complete empty inventory is definitive.
            return inventoryErrors.isEmpty
                ? .err(
                    code: "not_found",
                    message: sshSessionAttachNotFoundMessage(sessionID: sessionID),
                    data: ["session_id": sessionID]
                )
                : .err(
                    code: "unavailable",
                    message: sshSessionAttachStateUnavailableMessage(),
                    data: ["session_id": sessionID]
                )
        }

        return sshSessionAttachOwnerResult(
            sessionID: sessionID,
            requestedWorkspaceID: requestedWorkspaceID,
            owningWorkspaceIDs: matchingWorkspaceIDs
        )
    }

    private nonisolated func sshSessionAttachOwnerResult(
        sessionID: String,
        requestedWorkspaceID: UUID?,
        owningWorkspaceIDs: Set<UUID>
    ) -> V2CallResult {
        if let requestedWorkspaceID,
           !owningWorkspaceIDs.contains(requestedWorkspaceID) {
            let owningWorkspaceID = owningWorkspaceIDs.sorted { $0.uuidString < $1.uuidString }[0]
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

        if let requestedWorkspaceID {
            return .ok([
                "workspace_id": requestedWorkspaceID.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: requestedWorkspaceID),
            ])
        }

        guard owningWorkspaceIDs.count == 1,
              let workspaceID = owningWorkspaceIDs.first else {
            return .err(
                code: "invalid_params",
                message: sshSessionAttachAmbiguousMessage(
                    sessionID: sessionID,
                    owningWorkspaceIDs: owningWorkspaceIDs
                ),
                data: [
                    "session_id": sessionID,
                    "owning_workspace_ids": owningWorkspaceIDs
                        .sorted { $0.uuidString < $1.uuidString }
                        .map(\.uuidString),
                ]
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

    private nonisolated func sshSessionAttachAmbiguousMessage(
        sessionID: String,
        owningWorkspaceIDs: Set<UUID>
    ) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "cli.error.sshSessionAttachWorkspaceAmbiguous",
                defaultValue: "ssh-session-attach: session '%1$@' exists in multiple workspaces (%2$@). Pass --workspace <workspace> to choose one."
            ),
            sessionID,
            owningWorkspaceIDs
                .sorted { $0.uuidString < $1.uuidString }
                .map(\.uuidString)
                .joined(separator: ", ")
        )
    }
}

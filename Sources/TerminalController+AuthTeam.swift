import CmuxAuthRuntime
import CmuxControlSocket
import Foundation
import OSLog

private let authTeamLog = Logger(subsystem: "ai.manaflow.cmux", category: "auth-team")

extension TerminalController {
    /// Handles the shared team-selection socket actions used by the CLI.
    /// Keeping the mutation here means CLI and SwiftUI both call the same
    /// coordinator operation and receive the same rollback semantics.
    nonisolated func v2AuthTeamResponse(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.team.list":
            return v2Ok(id: request.id, result: v2AuthTeamStatusPayload())
        case "auth.team.use":
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: String(localized: "socket.authTeam.asyncRequired", defaultValue: "Team actions require asynchronous socket dispatch.")
            )
        case "auth.team.create":
            return v2Error(
                id: request.id,
                code: "invalid_dispatch",
                message: String(localized: "socket.authTeam.asyncRequired", defaultValue: "Team actions require asynchronous socket dispatch.")
            )
        default:
            return v2Error(
                id: request.id,
                code: "method_not_found",
                message: String(localized: "socket.authTeam.unknownMethod", defaultValue: "Unknown team action.")
            )
        }
    }

    private nonisolated func v2AuthTeamStatusPayload() -> [String: Any] {
        v2MainSync { self.v2AuthTeamStatusPayloadOnMain() }
    }

    /// Async socket path for team mutations. Socket connections must suspend
    /// while the MainActor-owned auth coordinator performs network work; they
    /// must not park a worker thread behind a semaphore.
    nonisolated func v2AuthTeamResponseAsync(_ request: ControlRequest) async throws -> String {
        let params = request.params.mapValues(\.foundationObject)
        let id = request.id?.foundationObject
        switch request.method {
        case "auth.team.list":
            return v2Ok(id: id, result: try await v2AuthTeamStatusPayloadAsync())
        case "auth.team.use":
            guard let teamID = params["team_id"] as? String,
                  !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingTeam", defaultValue: "A team id is required.")
                )
            }
            return try await v2AuthTeamMutationAsync(id: id) { flow in
                try await flow.selectTeam(id: teamID)
            }
        case "auth.team.create":
            guard let displayName = params["display_name"] as? String,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingName", defaultValue: "A team name is required.")
                )
            }
            return try await v2AuthTeamMutationAsync(id: id) { flow in
                _ = try await flow.createTeam(displayName: displayName)
            }
        default:
            return v2Error(
                id: id,
                code: "method_not_found",
                message: String(localized: "socket.authTeam.unknownMethod", defaultValue: "Unknown team action.")
            )
        }
    }

    private nonisolated func v2AuthTeamMutationAsync(
        id: Any?,
        action: @escaping @MainActor (HostAccountFlow) async throws -> Void
    ) async throws -> String {
        guard let flow = try await v2MainAsync({ self.accountFlow }) else {
            return v2Error(
                id: id,
                code: "auth_required",
                message: String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
            )
        }
        // The mutation and the post-mutation status read have separate error
        // boundaries: once `action` returns, the team change is committed and
        // must never be reported as a failure the client could retry (a
        // retried create would make a duplicate team).
        do {
            try await action(flow)
        } catch {
            authTeamLog.error("team mutation failed: \(String(describing: error), privacy: .private)")
            return v2Error(
                id: id,
                code: "team_selection_failed",
                message: v2AuthTeamUserMessage(error)
            )
        }
        do {
            return v2Ok(id: id, result: try await v2AuthTeamStatusPayloadAsync())
        } catch is SocketMainActorHopTimeout {
            return v2Error(
                id: id,
                code: "timeout",
                message: String(
                    localized: "socket.authTeam.committedStatusTimedOut",
                    defaultValue: "The team change was applied, but cmux did not report the updated status within 10 seconds. Run `cmux auth status` to confirm."
                ),
                data: [
                    "retryable": false,
                    "committed": true,
                    "deadline_ms": Self.socketMainActorHopDeadlineMilliseconds,
                    "stage": "main_actor",
                ]
            )
        }
    }

    private nonisolated func v2AuthTeamUserMessage(_ error: Error) -> String {
        switch error {
        case AuthError.unauthorized:
            return String(localized: "socket.authTeam.signedOut", defaultValue: "Sign in to manage teams.")
        case AuthClientError.teamNotAvailable:
            return String(localized: "socket.authTeam.notMember", defaultValue: "You are not a member of that team.")
        case AuthClientError.invalidTeamName:
            return String(localized: "socket.authTeam.invalidName", defaultValue: "Enter a team name.")
        default:
            return String(localized: "socket.authTeam.failed", defaultValue: "Could not update the team. Try again.")
        }
    }

    private nonisolated func v2AuthTeamStatusPayloadAsync() async throws -> [String: Any] {
        try await v2MainAsync {
            self.v2AuthTeamStatusPayloadOnMain()
        }
    }

    @MainActor
    private func v2AuthTeamStatusPayloadOnMain() -> [String: Any] {
        guard let coordinator = authCoordinator else {
            return ["signed_in": false, "teams": []]
        }
        var status: [String: Any] = ["signed_in": coordinator.isAuthenticated]
        if let teamID = coordinator.resolvedTeamID {
            status["selected_team_id"] = teamID
        }
        status["teams"] = coordinator.availableTeams.map { team in
            var value: [String: Any] = [
                "id": team.id,
                "display_name": team.displayName
            ]
            if let slug = team.slug { value["slug"] = slug }
            return value
        }
        return status
    }
}

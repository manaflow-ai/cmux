import CmuxAuthRuntime
import Foundation

extension TerminalController {
    /// Handles the shared team-selection socket actions used by the CLI.
    /// Keeping the mutation here means CLI and SwiftUI both call the same
    /// coordinator operation and receive the same rollback semantics.
    nonisolated func v2AuthTeamResponse(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.team.list":
            return v2Ok(id: request.id, result: v2AuthTeamStatusPayload())
        case "auth.team.use":
            guard let teamID = request.params["team_id"] as? String,
                  !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: request.id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingTeam", defaultValue: "A team id is required.")
                )
            }
            return v2AuthTeamMutation(request: request) { flow in
                try await flow.selectTeam(id: teamID)
            }
        case "auth.team.create":
            guard let displayName = request.params["display_name"] as? String,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return v2Error(
                    id: request.id,
                    code: "invalid_params",
                    message: String(localized: "socket.authTeam.missingName", defaultValue: "A team name is required.")
                )
            }
            return v2AuthTeamMutation(request: request) { flow in
                _ = try await flow.createTeam(displayName: displayName)
            }
        default:
            return v2Error(
                id: request.id,
                code: "method_not_found",
                message: String(localized: "socket.authTeam.unknownMethod", defaultValue: "Unknown team action.")
            )
        }
    }

    private nonisolated func v2AuthTeamMutation(
        request: V2SocketRequest,
        action: @escaping @MainActor (HostAccountFlow) async throws -> Void
    ) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task { @MainActor [weak self] in
            defer { semaphore.signal() }
            do {
                guard let flow = self?.accountFlow else { throw AuthError.unauthorized }
                try await action(flow)
            } catch {
                failure = error
            }
        }
        semaphore.wait()
        if let failure {
            return v2Error(
                id: request.id,
                code: "team_selection_failed",
                message: failure.localizedDescription
            )
        }
        return v2Ok(id: request.id, result: v2AuthTeamStatusPayload())
    }

    private nonisolated func v2AuthTeamStatusPayload() -> [String: Any] {
        var result: [String: Any] = [:]
        v2MainSync {
            MainActor.assumeIsolated {
                guard let coordinator = self.authCoordinator else {
                    result = ["signed_in": false, "teams": []]
                    return
                }
                var status: [String: Any] = [
                    "signed_in": coordinator.isAuthenticated
                ]
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
                result = status
            }
        }
        return result
    }
}

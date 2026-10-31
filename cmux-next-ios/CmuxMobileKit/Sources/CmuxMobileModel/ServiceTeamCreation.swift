import Foundation

/// Create Team through the cmux service (`POST /v1/teams`, PROTOCOL.md).
/// Stack refuses team creation from the client (`client_team_creation_enabled`
/// is off in both projects), so the service creates it with the project's
/// server key (full verify D1, 2026-10-19).
public struct ServiceTeamCreation: Sendable {
    /// Why a team could not be created.
    public enum Failure: Error, Equatable, Sendable {
        /// The service can't create teams for this account (no server key for its project).
        case unavailable
        case failed
    }

    public let apiBase: URL

    public init(apiBase: URL) {
        self.apiBase = apiBase
    }

    /// `POST /v1/teams {name}`.
    public func request(accessToken: String, name: String) -> URLRequest {
        var request = URLRequest(url: apiBase.appending(path: "v1/teams"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        return request
    }

    /// The created team from the service's answer; any other answer is an error, never a silent success.
    public func team(from data: Data, status: Int) throws -> AppStore.AccountTeam {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            throw code == "team_creation_unavailable" ? Failure.unavailable : Failure.failed
        }
        guard let team = object?["team"] as? [String: Any], let id = team["id"] as? String, !id.isEmpty else {
            throw Failure.failed
        }
        return AppStore.AccountTeam(id: id, name: team["name"] as? String ?? "")
    }
}

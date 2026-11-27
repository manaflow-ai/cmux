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
        /// The name is empty or longer than the server allows.
        case invalidName
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

/// Where Create Team goes for this build's account.
///
/// The cmux mobile service can create a team only for the Stack project it holds a server key
/// for. The production service (`mobile-api.cmux.dev`) holds none, so it answers every
/// production account `503 team_creation_unavailable`; the cmux team API (`POST
/// <cmux>/api/teams`), which the Mac uses, creates the team with its creator as admin.
public enum TeamCreationRoute: Equatable, Sendable {
    /// `POST <base>/api/teams` (CmuxAuthRuntime `CmuxTeamsAPI`).
    case teamAPI(URL)
    /// `POST <base>/v1/teams` (``ServiceTeamCreation``).
    case mobileService(URL)
    /// Neither is configured: Create Team says the account can't create teams.
    case unavailable

    /// - Parameters:
    ///   - productionAccount: The build signs in to the production Stack project.
    ///   - teamAPIBase: The cmux web API origin (`https://cmux.com` for production).
    ///   - mobileServiceBase: The cmux mobile service base, when configured.
    public init(productionAccount: Bool, teamAPIBase: URL?, mobileServiceBase: URL?) {
        if productionAccount, let teamAPIBase {
            self = .teamAPI(teamAPIBase)
        } else if let mobileServiceBase {
            self = .mobileService(mobileServiceBase)
        } else {
            self = .unavailable
        }
    }

    /// The cmux web origin for App Store plans (`<origin>/api/billing/apple/*`):
    /// the same production-account origin as the team API, since cmux.com
    /// accepts only production Stack sessions. Nil for every other build.
    public var billingOrigin: URL? {
        if case .teamAPI(let origin) = self { return origin }
        return nil
    }
}

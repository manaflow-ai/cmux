public import CmuxNextCodeRouter
import Foundation

/// ``TeamInviteBackend`` over the signed-in cmux.com client: the team list
/// (`GET /api/subrouter/teams`) and the team's email invite
/// (`POST /api/teams/{id}/invitations`, the dashboard's own route).
public nonisolated struct CmuxTeamInviteBackend: TeamInviteBackend {
    private let client: CodeRouterClient

    /// Creates the backend over the app's signed-in client.
    public init(client: CodeRouterClient) {
        self.client = client
    }

    public func teams() async throws -> [TeamInviteTeam] {
        struct Row: Decodable { var id: String; var name: String?; var personal: Bool? }
        struct Catalog: Decodable { var teams: [Row] }
        let data = try await call { try await client.request("GET", "/api/subrouter/teams") }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw TeamInviteBackendError(code: "bad_response", message: "cmux.com sent an unexpected team list")
        }
        return catalog.teams.map { TeamInviteTeam(id: $0.id, name: $0.name ?? $0.id, personal: $0.personal ?? false) }
    }

    public func invite(teamID: String, emails: [String], role: TeamInviteRole) async throws -> TeamInviteOutcome {
        struct Invitation: Decodable { var id: String; var email: String?; var role: String; var expiresAt: String }
        struct Failure: Decodable { var email: String; var code: String }
        struct Answer: Decodable { var invitations: [Invitation]; var failed: [Failure] }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let segment = teamID.addingPercentEncoding(withAllowedCharacters: allowed), !segment.isEmpty, segment != ".", segment != ".." else {
            throw TeamInviteBackendError(code: "invalid_params", message: "bad team id")
        }
        let body: [String: any Sendable] = ["emails": emails, "role": role.rawValue]
        let data = try await call { try await client.request("POST", "/api/teams/\(segment)/invitations", body: body, team: teamID) }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw TeamInviteBackendError(code: "bad_response", message: "cmux.com sent an unexpected invite answer")
        }
        return TeamInviteOutcome(
            invitations: answer.invitations.map { .init(id: $0.id, email: $0.email ?? "", role: $0.role, expiresAt: $0.expiresAt) },
            failed: answer.failed.map { .init(email: $0.email, code: $0.code) })
    }

    /// One call; the client's error becomes a ``TeamInviteBackendError`` whose code passes through (`team_admin_required`, `rate_limited`).
    private func call(_ body: @Sendable () async throws -> Data) async throws -> Data {
        do {
            return try await body()
        } catch let error as CodeRouterError {
            switch error {
            case .notSignedIn: throw TeamInviteBackendError(code: "not_signed_in", message: error.description)
            case .scopeChanged: throw TeamInviteBackendError(code: "scope_changed", message: error.description)
            case .timedOut: throw TeamInviteBackendError(code: "timeout", message: error.description)
            case .http(let status, let code, let message):
                throw TeamInviteBackendError(code: code ?? "http_\(status)", message: message ?? error.description)
            case .transport: throw TeamInviteBackendError(code: "unavailable", message: error.description)
            case .decoding: throw TeamInviteBackendError(code: "bad_response", message: error.description)
            }
        }
    }
}

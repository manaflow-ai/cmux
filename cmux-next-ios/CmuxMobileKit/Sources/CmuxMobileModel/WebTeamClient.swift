import Foundation

/// The cmux team API (`web/`, https://cmux.com in release), the same backend
/// the Mac app uses for teams: list with roles, create, read, rename, delete.
/// Native clients authenticate with the sign-in session's access token
/// (`Authorization: Bearer`) and refresh token (`X-Stack-Refresh-Token`).
/// Every error answer is `{ error: { code, message } }` (`TeamServiceError`).
public struct WebTeamClient: TeamManaging {
    /// The session's current tokens.
    public typealias Credentials = @Sendable () async throws -> (accessToken: String, refreshToken: String)
    /// Sends a request (URLSession in the app, a fake in tests).
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let base: URL
    private let credentials: Credentials
    private let transport: Transport

    public init(base: URL, credentials: @escaping Credentials, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.base = base
        self.credentials = credentials
        self.transport = transport
    }

    /// `GET /api/teams`: the account's teams with its role in each.
    public func listTeams() async throws -> TeamDirectory {
        let list: ListResponse = try await send("GET", ["api", "teams"])
        return TeamDirectory(
            teams: list.teams.map { TeamSummary(id: $0.id, displayName: $0.displayName, role: $0.role, permissions: $0.permissions) },
            selectedTeamID: list.selectedTeamId
        )
    }

    /// `POST /api/teams {displayName}`: the new team, with you as its admin.
    public func createTeam(named name: String) async throws -> AppStore.AccountTeam {
        let created: CreateResponse = try await send("POST", ["api", "teams"], body: ["displayName": name])
        guard !created.team.id.isEmpty else { throw TeamServiceError.malformed }
        return AppStore.AccountTeam(id: created.team.id, name: created.team.displayName, role: .admin)
    }

    /// `GET /api/teams/:id`.
    public func team(id: String) async throws -> TeamDetail {
        let detail: DetailResponse = try await send("GET", ["api", "teams", id])
        return detail.teamDetail
    }

    /// `PATCH /api/teams/:id {displayName}` (admins only).
    public func renameTeam(id: String, to name: String) async throws -> String {
        let updated: UpdateResponse = try await send("PATCH", ["api", "teams", id], body: ["displayName": name])
        return updated.team.displayName
    }

    /// `DELETE /api/teams/:id` (admins only; 409 `team_has_active_subscription`).
    public func deleteTeam(id: String) async throws {
        let _: OK = try await send("DELETE", ["api", "teams", id])
    }

    // MARK: Transport

    func request(_ method: String, _ path: [String], body: [String: String]?, tokens: (accessToken: String, refreshToken: String)) -> URLRequest {
        // Each component is one path segment: an id is escaped, never a path.
        let url = path.reduce(base) { $0.appending(component: $1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        return request
    }

    private func send<Response: Decodable>(_ method: String, _ path: [String], body: [String: String]? = nil) async throws -> Response {
        let tokens = try await credentials()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request(method, path, body: body, tokens: tokens))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TeamServiceError.unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TeamServiceError.malformed }
        guard (200..<300).contains(status) else {
            // Any 5xx is an outage (`service_unavailable`, `authentication_unavailable`,
            // a gateway page): callers fall back as for no answer.
            if status >= 500 { throw TeamServiceError.unreachable }
            if let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TeamServiceError.server(status: status, code: failure.error.code, message: failure.error.message ?? "")
            }
            // No team API answer at all (a gateway page, a server too old for the route).
            throw status == 404 ? TeamServiceError.unreachable : TeamServiceError.server(status: status, code: "", message: "")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TeamServiceError.malformed
        }
    }

    // MARK: Wire types (web/services/teams/types.ts)

    private struct ErrorResponse: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String?
        }
        let error: Body
    }

    private struct OK: Decodable {}

    private struct ListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let displayName: String
            let role: TeamRole
            let permissions: TeamPermissions
        }
        let teams: [Item]
        let selectedTeamId: String?
    }

    private struct CreateResponse: Decodable {
        struct Created: Decodable {
            let id: String
            let displayName: String
        }
        let team: Created
    }

    private struct UpdateResponse: Decodable {
        struct Updated: Decodable {
            let displayName: String
        }
        let team: Updated
    }

    private struct DetailResponse: Decodable {
        struct TeamInfo: Decodable {
            let id: String
            let displayName: String
        }
        struct Viewer: Decodable {
            let userId: String
            let role: TeamRole
            let permissions: TeamPermissions
        }
        struct Member: Decodable {
            let userId: String
            let displayName: String?
            let email: String?
            let role: TeamRole
            let isViewer: Bool
        }
        struct Invitation: Decodable {
            let id: String
            let email: String?
            let role: TeamRole
            let expiresAt: String?
        }
        struct Billing: Decodable {
            let planId: String?
            let seats: Int?
            let memberLimit: Int?
            let memberCount: Int
            let hasActiveSubscription: Bool
        }
        let team: TeamInfo
        let viewer: Viewer
        let members: [Member]
        let invitations: [Invitation]?
        let billing: Billing?

        var teamDetail: TeamDetail {
            TeamDetail(
                id: team.id,
                name: team.displayName,
                role: viewer.role,
                permissions: viewer.permissions,
                members: members.map { member in
                    let name = member.displayName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    return TeamDetail.Member(id: member.userId, name: name ?? member.email ?? String(localized: "Team member"),
                                             email: member.email, role: member.role, isYou: member.isViewer || member.userId == viewer.userId)
                },
                invitations: (invitations ?? []).map {
                    TeamDetail.Invitation(id: $0.id, email: $0.email, role: $0.role, expiresAt: $0.expiresAt.flatMap(Self.date))
                },
                billing: billing.map {
                    TeamDetail.Billing(planID: $0.planId, seats: $0.seats, memberLimit: $0.memberLimit, memberCount: $0.memberCount,
                                       hasActiveSubscription: $0.hasActiveSubscription)
                }
            )
        }

        /// ISO 8601, with or without fractional seconds (JavaScript's `toISOString`).
        static func date(_ string: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
    }
}

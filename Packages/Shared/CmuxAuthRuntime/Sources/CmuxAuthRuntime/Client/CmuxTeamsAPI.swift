public import CMUXAuthCore
public import Foundation

/// The cmux team API (`<apiBaseURL>/api/teams`): the signed-in user's teams
/// with roles, one team's detail, create, rename and delete, and email invitations. Every request
/// carries the native session pair (`Authorization: Bearer <access>` and
/// `X-Stack-Refresh-Token: <refresh>`), as every other cmux API call does.
/// Failures are ``CMUXTeamError``.
public struct CmuxTeamsAPI: Sendable {
    /// The session pair for one request, or nil when signed out.
    public typealias Credentials = @Sendable () async throws -> (access: String, refresh: String)?

    private let baseURL: URL
    private let session: URLSession
    private let credentials: Credentials

    /// - Parameters:
    ///   - baseURL: The cmux API origin (`https://cmux.com`, or a DEV build's backend).
    ///   - session: The URL session requests go through.
    ///   - credentials: Reads the session pair for each request.
    public init(baseURL: URL, session: URLSession = .shared, credentials: @escaping Credentials) {
        self.baseURL = baseURL
        self.session = session
        self.credentials = credentials
    }

    /// `GET /api/teams`: the user's teams, each with the user's role and permissions.
    public func memberships() async throws -> CMUXTeamMemberships {
        let list: TeamListResponse = try await send("GET", ["api", "teams"])
        return CMUXTeamMemberships(
            teams: list.teams.map {
                CMUXTeamMembership(id: $0.id, displayName: $0.displayName, profileImageURL: $0.profileImageUrl,
                                   role: $0.role.flatMap(CMUXTeamRole.init(rawValue:)),
                                   permissions: $0.permissions ?? CMUXTeamPermissions())
            },
            selectedTeamID: list.selectedTeamId)
    }

    /// `GET /api/teams/:id`: the team, the user's role, members, pending invitations and billing.
    public func detail(teamID: String) async throws -> CMUXTeamDetail {
        try await send("GET", ["api", "teams", teamID])
    }

    /// `POST /api/teams`: creates a team; the creator becomes its admin.
    public func create(displayName: String) async throws -> CMUXAuthTeam {
        let name = try CMUXTeamName(displayName, maximumLength: CMUXTeamName.serverMaximumLength)
        let reply: TeamReply = try await send("POST", ["api", "teams"], body: NameBody(displayName: name.value))
        return CMUXAuthTeam(id: reply.team.id, displayName: reply.team.displayName)
    }

    /// `PATCH /api/teams/:id`: renames a team (admins only).
    public func rename(teamID: String, displayName: String) async throws -> CMUXAuthTeam {
        let name = try CMUXTeamName(displayName, maximumLength: CMUXTeamName.serverMaximumLength)
        let reply: TeamReply = try await send("PATCH", ["api", "teams", teamID], body: NameBody(displayName: name.value))
        return CMUXAuthTeam(id: reply.team.id, displayName: reply.team.displayName)
    }

    /// `DELETE /api/teams/:id`: deletes a team (admins only). Refused with
    /// ``CMUXTeamError/subscriptionActive`` while the team has a subscription.
    public func delete(teamID: String) async throws {
        _ = try await perform("DELETE", ["api", "teams", teamID], body: nil)
    }

    /// `POST /api/teams/:id/invitations`: invites each address to the team (admins, or a member
    /// the team lets invite). The server emails each invitation; joining is a billable member
    /// change on a paid team (a Team plan's seat count follows its members).
    ///
    /// - Parameters:
    ///   - teamID: The team.
    ///   - emails: 1 to 20 addresses.
    ///   - role: The role each gets on joining (`member` unless an admin is meant).
    /// - Returns: The invitations sent and the addresses refused (already members, unsendable).
    /// - Throws: ``CMUXTeamError``: `forbidden` without the invite permission, `unavailable` on a
    ///   rate limit or network failure.
    public func invite(teamID: String, emails: [String], role: CMUXTeamRole = .member) async throws -> CMUXTeamInviteResult {
        try await send("POST", ["api", "teams", teamID, "invitations"], body: InviteBody(emails: emails, role: role.rawValue))
    }

    private func send<Reply: Decodable>(_ method: String, _ path: [String], body: (any Encodable)? = nil) async throws -> Reply {
        let data = try await perform(method, path, body: body)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw CMUXTeamError.unavailable
        }
    }

    /// Sends one request and answers the body of a 2xx reply.
    private func perform(_ method: String, _ path: [String], body: (any Encodable)?) async throws -> Data {
        guard let pair = try await credentials() else { throw CMUXTeamError.signedOut }
        // Each id is one escaped path segment.
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(pair.access)", forHTTPHeaderField: "Authorization")
        request.setValue(pair.refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CMUXTeamError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw CMUXTeamError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.code
            throw CMUXTeamError(status: http.statusCode, code: code)
        }
        return data
    }
}

private struct NameBody: Encodable {
    let displayName: String
}

private struct InviteBody: Encodable {
    let emails: [String]
    let role: String
}

private struct TeamReply: Decodable {
    struct Team: Decodable {
        let id: String
        let displayName: String
    }

    let team: Team
}

private struct TeamListResponse: Decodable {
    struct Team: Decodable {
        let id: String
        let displayName: String
        let profileImageUrl: String?
        let role: String?
        let permissions: CMUXTeamPermissions?
    }

    let teams: [Team]
    let selectedTeamId: String?
}

private struct ErrorReply: Decodable {
    struct Body: Decodable {
        let code: String?
    }

    let error: Body
}

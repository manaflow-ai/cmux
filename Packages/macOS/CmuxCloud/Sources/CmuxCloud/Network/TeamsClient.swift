import CmuxAuthRuntime
import Foundation

/// Team roster and invitation client for `/api/teams/[teamId]/...`.
///
/// Mirrors ``RemotesClient``: an actor with an injected ``AuthCoordinator``
/// and ``URLSession`` that attaches the Stack bearer + refresh headers to every
/// request. This is the single path behind the Cloud team picker, Settings,
/// the `auth.team.*` socket methods and the `cmux auth team` CLI verbs, so
/// every entrypoint shares one request shape and one error mapping.
public actor TeamsClient {
    @MainActor public private(set) static var shared: TeamsClient!

    /// False until `bootstrap` ran; hosts that poll on sign-in check this so a
    /// test with a fake coordinator and no client never dereferences nil.
    @MainActor public static var isBootstrapped: Bool { shared != nil }

    @MainActor
    public static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = TeamsClient(session: session, auth: auth)
    }

    private let session: URLSession
    private let auth: AuthCoordinator
    private let baseURL: () -> URL

    public init(
        session: URLSession = .shared,
        auth: AuthCoordinator,
        baseURL: @escaping @Sendable () -> URL = { AuthEnvironment.vmAPIBaseURL }
    ) {
        self.session = session
        self.auth = auth
        self.baseURL = baseURL
    }

    // MARK: - Public operations

    /// The roster, pending invitations, links and billing summary of one team.
    /// Invitations and links come back empty for non-admins.
    public func detail(teamID: String) async throws -> CloudTeamDetail {
        let team = try Self.pathSegment(teamID)
        let (data, http) = try await request("GET", path: "/api/teams/\(team)")
        try ensureOK(http, data: data)
        return try Self.decoder.decode(CloudTeamDetail.self, from: data)
    }

    /// Pending invitations addressed to the signed-in user's verified emails.
    public func receivedInvitations() async throws -> [CloudReceivedInvitation] {
        let (data, http) = try await request("GET", path: "/api/teams/invitations")
        try ensureOK(http, data: data)
        struct Envelope: Decodable { let invitations: [CloudReceivedInvitation] }
        return try Self.decoder.decode(Envelope.self, from: data).invitations
    }

    /// Join the team an invitation names. The verified email is the proof.
    public func acceptInvitation(invitationID: String) async throws -> CloudTeamAcceptResult {
        let invitation = try Self.pathSegment(invitationID)
        let (data, http) = try await request("POST", path: "/api/teams/invitations/\(invitation)/accept")
        try ensureOK(http, data: data)
        return try Self.decoder.decode(CloudTeamAcceptResult.self, from: data)
    }

    public func declineInvitation(invitationID: String) async throws {
        let invitation = try Self.pathSegment(invitationID)
        let (data, http) = try await request("POST", path: "/api/teams/invitations/\(invitation)/decline")
        try ensureOK(http, data: data)
    }

    /// Invite up to 20 emails with one role. cmux emails each address.
    public func invite(
        teamID: String,
        emails: [String],
        role: CloudTeamRole
    ) async throws -> CloudTeamInviteResult {
        let cleaned = emails
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw TeamsClientError.invalidEmail }
        let team = try Self.pathSegment(teamID)
        let (data, http) = try await request(
            "POST",
            path: "/api/teams/\(team)/invitations",
            jsonBody: ["emails": cleaned, "role": role.rawValue]
        )
        try ensureOK(http, data: data)
        return try Self.decoder.decode(CloudTeamInviteResult.self, from: data)
    }

    /// Create a reusable member-only link. The raw URL appears only in this
    /// response; the server stores a hash.
    public func createInviteLink(
        teamID: String,
        expiresInDays: Int?,
        maxUses: Int?
    ) async throws -> CloudTeamInviteLinkCreated {
        if let expiresInDays, ![1, 7, 30].contains(expiresInDays) {
            throw TeamsClientError.invalidLinkOptions
        }
        if let maxUses, maxUses < 1 {
            throw TeamsClientError.invalidLinkOptions
        }
        let body: [String: Any] = [
            "expiresInDays": expiresInDays.map { $0 as Any } ?? NSNull(),
            "maxUses": maxUses.map { $0 as Any } ?? NSNull(),
        ]
        let team = try Self.pathSegment(teamID)
        let (data, http) = try await request(
            "POST",
            path: "/api/teams/\(team)/links",
            jsonBody: body
        )
        try ensureOK(http, data: data)
        return try Self.decoder.decode(CloudTeamInviteLinkCreated.self, from: data)
    }

    public func revokeInvitation(teamID: String, invitationID: String) async throws {
        let team = try Self.pathSegment(teamID)
        let invitation = try Self.pathSegment(invitationID)
        let (data, http) = try await request("DELETE", path: "/api/teams/\(team)/invitations/\(invitation)")
        try ensureOK(http, data: data)
    }

    public func revokeInviteLink(teamID: String, linkID: String) async throws {
        let team = try Self.pathSegment(teamID)
        let link = try Self.pathSegment(linkID)
        let (data, http) = try await request("DELETE", path: "/api/teams/\(team)/links/\(link)")
        try ensureOK(http, data: data)
    }

    /// Remove a member (admin), or leave the team when `userID` is the caller.
    public func removeMember(teamID: String, userID: String) async throws {
        let team = try Self.pathSegment(teamID)
        let user = try Self.pathSegment(userID)
        let (data, http) = try await request("DELETE", path: "/api/teams/\(team)/members/\(user)")
        try ensureOK(http, data: data)
    }

    public func changeMemberRole(teamID: String, userID: String, role: CloudTeamRole) async throws -> CloudTeamMember {
        let team = try Self.pathSegment(teamID)
        let user = try Self.pathSegment(userID)
        let (data, http) = try await request(
            "PATCH",
            path: "/api/teams/\(team)/members/\(user)",
            jsonBody: ["role": role.rawValue]
        )
        try ensureOK(http, data: data)
        struct Envelope: Decodable { let member: CloudTeamMember }
        return try Self.decoder.decode(Envelope.self, from: data).member
    }

    // MARK: - HTTP

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Every team date is written by `Date.toISOString()` on the web, which
        // always emits milliseconds, and `.iso8601` rejects fractional seconds.
        // Accept both shapes, the way `VMClient` already does. The format
        // styles are Sendable, unlike `ISO8601DateFormatter`.
        let withFractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let wholeSeconds = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = (try? Date(raw, strategy: withFractions))
                ?? (try? Date(raw, strategy: wholeSeconds)) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 team date, got \"\(raw)\""
                )
            }
            return date
        }
        return decoder
    }()

    static func pathSegment(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encoded.contains("/") else {
            throw TeamsClientError.invalidIdentifier
        }
        return encoded
    }

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard ManagedCloudPolicy.isEnabled else { throw VMClientError.disabledByManagedPolicy }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch AuthError.networkError, AuthError.timedOut {
            throw TeamsClientError.sessionRefreshFailed
        } catch {
            throw TeamsClientError.notSignedIn
        }
        let base = baseURL()
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw TeamsClientError.malformedResponse("bad vmAPIBaseURL")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        guard let url = comps.url else {
            throw TeamsClientError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                throw TeamsClientError.backendUnreachable(detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw TeamsClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            throw TeamsClientError.from(status: http.statusCode, body: data)
        }
    }
}

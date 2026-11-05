public import Foundation

/// Whether a Cloud machine's git can borrow GitHub through the cmux GitHub App (`cmux github setup`
/// on the machine: a git credential helper that asks cmux for a short-lived, one-repo token each
/// time, and stores none). Read from the API Worker's own check, `GET /v1/integrations/github/status`,
/// which says whether this deployment has the App and which team connection the person would use:
/// the same connection the token endpoint mints from, and refuses with `integration.not_found` without.
public enum CloudGitHubApp: String, Equatable, Sendable {
    /// The App is configured and the team has an active connection.
    case ready
    /// No usable connection for this team (the token endpoint's `integration.not_found`), or one that
    /// needs to be connected again.
    case notConnected = "not_connected"
    /// This deployment has no cmux GitHub App.
    case notConfigured = "not_configured"
    /// The check did not answer (signed out, offline, or the Worker could not check).
    case unknown

    /// The status route's answer: `{configured, app_slug, connection: {status, …} | null}`, else
    /// `{error: {code, message}}`.
    public init(status: Int, body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status), let object else {
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            self = code == "integration.not_found" ? .notConnected : .unknown
            return
        }
        guard let configured = object["configured"] as? Bool else { self = .unknown; return }
        guard configured else { self = .notConfigured; return }
        // A configured deployment names its App; an answer that does not is not this route's.
        guard let slug = object["app_slug"] as? String, !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self = .unknown
            return
        }
        // The team policy disallows GitHub: the App mints nothing, so the helper must not replace
        // the machine's own sign-in. An older Worker that does not say is allowed, as before.
        guard object["allowed"] as? Bool != false else { self = .unknown; return }
        let connection = object["connection"] as? [String: Any]
        self = connection?["status"] as? String == "active" ? .ready : .notConnected
    }

    /// The route's path for `team` (a `team_…` id); nil for anything else, so no other text reaches the URL.
    public static func path(team: String) -> String? {
        let id = team.utf8.dropFirst(5)
        guard team.hasPrefix("team_"), (1...120).contains(id.count), id.allSatisfy(idBytes.contains) else { return nil }
        return "/v1/integrations/github/status?team=\(team)"
    }

    private static let idBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
}

extension CloudOwnerAPIClient {
    /// `GET /v1/integrations/github/status?team=` with the person's own session: whether `team`'s
    /// Cloud machines can use the cmux GitHub App. Never throws: a check that does not answer is
    /// ``CloudGitHubApp/unknown``, and the caller falls back to the machine's own GitHub sign-in.
    public func gitHubApp(team: String) async -> CloudGitHubApp {
        guard let path = CloudGitHubApp.path(team: team),
              let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              let access = try? await accessToken() else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        // Only Authorization (the Worker's invocation log masks it): the team in the query is no secret.
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let session = session, prepared = request
        guard let answer = try? await withDeadline(.seconds(15), label: "GET \(path)", { try await session.data(for: prepared) }),
              let http = answer.1 as? HTTPURLResponse else { return .unknown }
        return CloudGitHubApp(status: http.statusCode, body: answer.0)
    }
}

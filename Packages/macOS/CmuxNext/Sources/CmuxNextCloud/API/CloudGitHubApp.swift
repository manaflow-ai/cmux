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

    /// Only the App installation page `integration.connect` answers may open (https://github.com/apps/<slug>/installations/new).
    public static func installationURL(_ raw: String) -> URL? {
        gitHubPage(raw, path: #"^/apps/[A-Za-z0-9-]+/installations/new$"#)
    }

    /// The `exp` of the signed `state` an installation page carries; nil when it carries none. Only a cache hint:
    /// the API verifies the state on completion.
    public static func authorizationExpiry(_ url: URL) -> Date? {
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let expires = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: expires)
    }

    /// `raw` when it is an https://github.com page whose path matches `path`, with no user, password or port.
    static func gitHubPage(_ raw: String, path: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.range(of: path, options: .regularExpression) != nil else { return nil }
        return url
    }
}

extension CloudOwnerAPIClient {
    /// `GET /v1/integrations/github/status?team=` with the person's own session: whether `team`'s
    /// Cloud machines can use the cmux GitHub App. Never throws: a check that does not answer is
    /// ``CloudGitHubApp/unknown``, and the caller falls back to the machine's own GitHub sign-in.
    public func gitHubApp(team: String) async -> CloudGitHubApp {
        await gitHubAppStatus(team: team).app
    }
}

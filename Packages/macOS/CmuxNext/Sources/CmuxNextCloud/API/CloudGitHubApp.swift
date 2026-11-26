public import Foundation

/// Whether a Cloud machine's git can borrow GitHub through the cmux GitHub App (`cmux github setup`
/// on the machine: a git credential helper that asks cmux for a short-lived, one-repo token each
/// time, and stores none). Read from the API Worker's own check, `GET /v1/integrations/github/status`,
/// which says whether this deployment has the App and which team connection the person would use:
/// the same connection the token endpoint mints from, and refuses with `integration.not_found` without.
public enum CloudGitHubApp: String, Equatable, Sendable {
    /// The App is configured and the team has an active connection.
    case ready
    /// No usable connection for this team (the token endpoint's `integration.not_found`).
    case notConnected = "not_connected"
    /// Linked, but GitHub no longer honors it: the installation was suspended or uninstalled (`needs_reauth`).
    /// ``reauthDetail(status:body:)`` is the server's reason when it gave one, ``configureURL(status:body:)`` the
    /// installation's settings page when it named one (a suspended install is fixed there, not by a new Connect).
    case needsReauth = "needs_reauth"
    /// A link is under way: the connection is `pending`, waiting for the person to finish on GitHub.
    case linking
    /// The connection is in the server's `error` state.
    case error
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
        self = Self.state(ofConnection: connection?["status"] as? String)
    }

    /// The state of a connection's server `status`: each of `needs_reauth`, `pending` and `error` is its own, and any
    /// other (none, `revoked`, `expired`, a status this build does not know) is not connected.
    static func state(ofConnection status: String?) -> CloudGitHubApp {
        switch status {
        case "active": .ready
        case "needs_reauth": .needsReauth
        case "pending": .linking
        case "error": .error
        default: .notConnected
        }
    }

    /// The server's own words for why the connection needs to be linked again (`status_detail`, else `detail`), trimmed
    /// and capped; nil when the body gives none or the connection is not ``needsReauth``. The status route sends none
    /// today; a Worker that adds one shows it.
    public static func reauthDetail(status: Int, body: Data) -> String? {
        guard CloudGitHubApp(status: status, body: body) == .needsReauth,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let connection = object["connection"] as? [String: Any] else { return nil }
        let raw = (connection["status_detail"] as? String) ?? (connection["detail"] as? String) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    /// The route's path for `team` (a `team_…` id); nil for anything else, so no other text reaches the URL.
    public static func path(team: String) -> String? {
        let id = team.utf8.dropFirst(5)
        guard team.hasPrefix("team_"), (1...120).contains(id.count), id.allSatisfy(idBytes.contains) else { return nil }
        return "/v1/integrations/github/status?team=\(team)"
    }

    private static let idBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)

    /// Only the pages `integration.connect` answers may open: the App's installation page
    /// (https://github.com/apps/<slug>/installations/new, or `/new/permissions` preselecting the repository's owner), or,
    /// for a repository whose owner has the App installed already, GitHub's authorize page
    /// (https://github.com/login/oauth/authorize), which comes back with a code and no install step (#55104).
    public static func installationURL(_ raw: String) -> URL? {
        gitHubPage(raw, path: #"^(/apps/[A-Za-z0-9-]+/installations/new(/permissions)?|/login/oauth/authorize)$"#)
    }

    /// A ready (or suspended, ``needsReauth``) connection's installation settings (`connection.configure_url`), where the
    /// person adds repositories or lifts a suspension: https://github.com/settings/installations/N, or
    /// /organizations/<org>/settings/installations/N. Nil for any other state, when an older Worker does not say, or for
    /// any other page.
    public static func configureURL(status: Int, body: Data) -> URL? {
        let app = CloudGitHubApp(status: status, body: body)
        // An uninstalled App has no settings page left: only a suspension is lifted there.
        guard app == .ready || (app == .needsReauth && reauthDetail(status: status, body: body)?.lowercased().contains("uninstall") != true),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let raw = (object["connection"] as? [String: Any])?["configure_url"] as? String else { return nil }
        return gitHubPage(raw, path: #"^(/organizations/[A-Za-z0-9-]+)?/settings/installations/[0-9]+$"#)
    }

    /// Settings' Reconfigure for a ready connection: its installation settings (``configureURL(status:body:)``), where
    /// the person changes which repositories the App reaches, else the App's own installation chooser on GitHub
    /// (https://github.com/apps/<slug>/installations/new, no `state`), which lists each account and org the App is on
    /// with Configure. Nil when not ready, or when the answer names no usable App slug.
    public static func reconfigureURL(status: Int, body: Data) -> URL? {
        if let page = configureURL(status: status, body: body) { return page }
        guard CloudGitHubApp(status: status, body: body) == .ready,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let slug = object["app_slug"] as? String,
              slug.range(of: #"^[A-Za-z0-9-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        return installationURL("https://github.com/apps/\(slug)/installations/new")
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

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
}

extension CloudOwnerAPIClient {
    /// Whether `team`'s Cloud machines can use the cmux GitHub App, with the person's own session
    /// (`cloud.owner.github_app`: `GET /v1/integrations/github/status?team=`, read by
    /// cmux-cloud-machine `github::status`). Never throws: a check that does not answer is
    /// ``CloudGitHubApp/unknown``, and the caller falls back to the machine's own GitHub sign-in.
    public func gitHubApp(team: String) async -> CloudGitHubApp {
        struct Answer: Decodable { var state: String }
        guard let data = try? await call("owner.github_app", ["team": team], wait: .seconds(15)),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return .unknown }
        return CloudGitHubApp(rawValue: answer.state) ?? .unknown
    }
}

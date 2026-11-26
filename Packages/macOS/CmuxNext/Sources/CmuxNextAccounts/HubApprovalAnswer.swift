public import CmuxNextCloud
public import Foundation

/// Settings > Integrations answers an integrations hub approval with the app's own Cloud sign-in, on
/// the person's click (SettingsIntegrationsHub in CmuxNextAgentIntegrations): never through the
/// `cmux hub` CLI, which has no verb for it, since a lane running the CLI holds the person's token.
@MainActor
public struct HubApprovalAnswer {
    public init() {}
    /// POSTs `body` to `path` at `platform` with AUTH's bearer (and `x-cmux-team` when a team is
    /// named) while ALLOWED says Cloud may be called: `(status, body)`.
    public static func poster(auth: CloudAuth, allowed: @escaping @MainActor () -> Bool)
        -> @MainActor (URL, String?, String, Data) async throws -> (Int, Data) {
        { platform, team, path, body in
            guard allowed() else { throw URLError(.cancelled) }
            let access = try await auth.tokens().access
            let reply = try await InstallHTTPTransport(baseURL: platform, buildSpace: auth.configuration.buildSpace)
                .post(path, json: body, bearer: access, headers: team.map { ["x-cmux-team": $0] } ?? [:])
            return (reply.status, reply.body)
        }
    }
}

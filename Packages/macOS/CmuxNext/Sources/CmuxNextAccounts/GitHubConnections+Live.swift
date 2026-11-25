public import CmuxNextCloud
import CmuxNextPages
import CmuxNextSettings
public import Foundation

extension GitHubConnections {
    /// The signed-in person's scope, or nil while a managed team other than the selected one is enforced.
    public static func signedInScope(project: String, user: String, team: String?, managedTeam: String?) -> Scope? {
        guard managedTeam == nil || team == managedTeam else { return nil }
        return Scope(user: backendUser(project: project, stackUser: user), team: team)
    }

    /// The connections of the Cloud sign-in AUTH, through the owner API at OWNER_API; PREVIEW (showcase or
    /// fixture launches) is always signed out. The GitHub App installation page opens through LinkRouter.
    public static func live(auth: CloudAuth, ownerAPI: URL, preview: Bool) -> GitHubConnections {
        let transport = InstallHTTPTransport(baseURL: ownerAPI)
        let current: @MainActor () -> Scope? = {
            guard !preview, auth.isSignedIn, let user = auth.user?.id else { return nil }
            return signedInScope(project: auth.configuration.stackProjectID, user: user, team: auth.teamID, managedTeam: auth.managedTeamID)
        }
        return GitHubConnections(scope: current, call: { bound, op, params, mutationKey in
            let access = try await auth.tokens().access
            guard current() == bound else { throw GitHubFailure.changedAccount }
            var body: [String: JSONValue] = ["op": .string(op), "params": params]
            if let mutationKey {
                body["origin"] = "user"
                body["idempotency_key"] = .string(mutationKey)
            }
            var headers: [String: String] = [:]
            if let team = backendTeam(project: auth.configuration.stackProjectID, stackTeam: bound.team) { headers["x-cmux-team"] = team }
            let response = try await transport.post(mutationKey != nil ? "v1/ops" : "v1/read", json: Data(JSONValue.object(body).compactText.utf8), bearer: access, headers: headers)
            guard current() == bound else { throw GitHubFailure.changedAccount }
            // A timeout, throttling response or server failure does not prove that
            // the mutation was refused. Keep its key for a safe retry.
            guard response.status < 500, response.status != 408, response.status != 429 else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.status) else { throw GitHubFailure.refused }
            let reply = try JSONValue.parse(response.body)
            guard (reply["error"] == nil || reply["error"] == .null), reply["ok"] != .bool(false), let value = reply["value"] else { throw GitHubFailure.refused }
            return value
        }, open: { url in LinkRouter.shared.open(url) })
    }
}
